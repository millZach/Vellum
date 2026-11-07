"""A small Dropbox client for the laptop indexer: sign in once with PKCE, keep the refresh token in Windows Credential
Manager, and download an online-only file straight to the scratch folder through ``files/download``.

The download never goes through the laptop's Dropbox folder: opening the placeholder there would make Dropbox pull the
file down into it. The app is Vellum's own Dropbox app (docs/dropbox.md), signed in with PKCE and no app secret, as the
Duo does (ADR-0013). Its app key comes from the laptop's settings.toml, never from the repository. The refresh token is
kept by ``keyring`` (Windows Credential Manager on the laptop) and is never written to a file, the state file or the
log; the access token lives only in memory.

Every HTTP call goes through ``transport``, so the tests drive a scripted Dropbox with no network.
"""

from __future__ import annotations

import base64
import contextlib
import hashlib
import http.client
import json
import logging
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

log = logging.getLogger("vellum_indexer")

AUTHORIZE_URL = "https://www.dropbox.com/oauth2/authorize"
TOKEN_URL = "https://api.dropboxapi.com/oauth2/token"
REVOKE_URL = "https://api.dropboxapi.com/2/auth/token/revoke"
DOWNLOAD_URL = "https://content.dropboxapi.com/2/files/download"
KEYRING_SERVICE = "Vellum laptop indexer"
CHUNK = 1024 * 1024
ATTEMPTS = 6


class DropboxError(Exception):
    """A call that did not work. Its message never holds a token."""


class NotSignedIn(DropboxError):
    pass


@dataclass
class Response:
    status: int
    headers: dict[str, str]  # lower-case names
    body: object  # has read(n)

    def read_all(self) -> bytes:
        return self.body.read()


Transport = Callable[[str, dict[str, str], bytes | None], Response]


def urllib_transport(url: str, headers: dict[str, str], body: bytes | None) -> Response:
    request = urllib.request.Request(url, data=body if body is not None else b"", headers=headers, method="POST")
    try:
        reply = urllib.request.urlopen(request, timeout=120)  # noqa: S310 - fixed https URLs
        return Response(reply.status, {k.lower(): v for k, v in reply.headers.items()}, reply)
    except urllib.error.HTTPError as error:
        return Response(error.code, {k.lower(): v for k, v in (error.headers or {}).items()}, error)
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise DropboxError(f"no connection to Dropbox ({type(error).__name__})") from None


class TokenStore(Protocol):
    def get(self) -> str | None: ...
    def put(self, token: str) -> None: ...
    def delete(self) -> None: ...


class KeyringTokenStore:
    """The refresh token in the operating system's credential store: Windows Credential Manager on the laptop."""

    def __init__(self, app_key: str):
        self.user = f"dropbox:{app_key}"

    def get(self) -> str | None:
        import keyring

        try:
            return keyring.get_password(KEYRING_SERVICE, self.user)
        except Exception:  # noqa: BLE001 - no credential store means not signed in
            return None

    def put(self, token: str) -> None:
        import keyring

        keyring.set_password(KEYRING_SERVICE, self.user, token)

    def delete(self) -> None:
        """Remove the token; raises if Credential Manager still holds it afterwards."""
        import keyring

        with contextlib.suppress(Exception):  # "not found" is fine; a token left behind is checked below
            keyring.delete_password(KEYRING_SERVICE, self.user)
        if self.get():
            raise DropboxError('Windows Credential Manager still holds the Dropbox token: remove "Vellum laptop '
                               'indexer" from Windows Credentials by hand')


class MemoryTokenStore:
    def __init__(self, token: str | None = None):
        self.token = token

    def get(self) -> str | None:
        return self.token

    def put(self, token: str) -> None:
        self.token = token

    def delete(self) -> None:
        self.token = None


def pkce_pair() -> tuple[str, str]:
    """A PKCE verifier and its S256 challenge."""
    verifier = secrets.token_urlsafe(64)[:96]
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest()).rstrip(b"=").decode()
    return verifier, challenge


def content_hash_of(path: Path) -> str:
    from vellum_indexer.pdf import dropbox_content_hash

    return dropbox_content_hash(path)


class DropboxClient:
    def __init__(
        self,
        app_key: str,
        tokens: TokenStore,
        transport: Transport = urllib_transport,
        sleep: Callable[[float], None] = time.sleep,
        clock: Callable[[], float] = time.monotonic,
    ):
        self.app_key = app_key
        self.tokens = tokens
        self.transport = transport
        self.sleep = sleep
        self.clock = clock
        self._access: str | None = None
        self._expires = 0.0

    # --- Signing in ---

    def signed_in(self) -> bool:
        return bool(self.tokens.get())

    def sign_in_url(self, challenge: str) -> str:
        """Dropbox's authorize page. With no redirect URI, Dropbox shows a code to paste back."""
        query = {"client_id": self.app_key, "response_type": "code", "code_challenge": challenge,
                 "code_challenge_method": "S256", "token_access_type": "offline"}
        return f"{AUTHORIZE_URL}?{urllib.parse.urlencode(query)}"

    def finish_sign_in(self, code: str, verifier: str) -> None:
        reply = self._token_call({"grant_type": "authorization_code", "code": code.strip(),
                                  "client_id": self.app_key, "code_verifier": verifier})
        refresh = reply.get("refresh_token")
        if not refresh:
            raise DropboxError("Dropbox gave no refresh token")
        self.tokens.put(refresh)
        self._remember(reply)

    def sign_out(self) -> None:
        """Forget the token on the laptop first, then ask Dropbox to end the sign-in. Raises when the laptop still
        holds the token, after asking Dropbox to end the sign-in anyway, so the token left behind is dead."""
        refresh = self.tokens.get()
        kept: DropboxError | None = None
        try:
            self.tokens.delete()
        except DropboxError as error:
            kept = error
        if refresh:
            try:
                self._refresh(refresh)
                self.transport(REVOKE_URL, {"Authorization": f"Bearer {self._access}"}, None)
            except DropboxError:
                log.info("Signed out on the laptop; Dropbox was not told (offline or refused)")
        self._access = None
        if kept is not None:
            raise kept

    # --- Tokens ---

    def _token_call(self, form: dict[str, str]) -> dict:
        body = urllib.parse.urlencode(form).encode()
        reply = self.transport(TOKEN_URL, {"Content-Type": "application/x-www-form-urlencoded"}, body)
        data = reply.read_all()
        if reply.status != 200:
            raise DropboxError(f"Dropbox refused the sign-in ({reply.status})")
        try:
            return json.loads(data)
        except ValueError:
            raise DropboxError("Dropbox's token reply was not JSON") from None

    def _remember(self, reply: dict) -> None:
        self._access = reply.get("access_token")
        self._expires = self.clock() + float(reply.get("expires_in", 14400)) - 300

    def _refresh(self, refresh: str) -> None:
        self._remember(self._token_call({"grant_type": "refresh_token", "refresh_token": refresh,
                                         "client_id": self.app_key}))

    def _access_token(self) -> str:
        if self._access and self.clock() < self._expires:
            return self._access
        refresh = self.tokens.get()
        if not refresh:
            raise NotSignedIn("not signed in to Dropbox")
        self._refresh(refresh)
        return self._access

    # --- Downloading ---

    def download(self, db_path: str, dest: Path) -> int:
        """The file at ``db_path`` into ``dest``, checked against Dropbox's size and content hash. Retries a 429 or a
        5xx with backoff, renews the access token once on a 401. ``dest`` does not exist after a failure."""
        arg = json.dumps({"path": db_path}, ensure_ascii=True)  # a header must be ASCII; Dropbox reads \\u escapes
        renewed = False
        for attempt in range(ATTEMPTS):
            try:
                headers = {"Authorization": f"Bearer {self._access_token()}", "Dropbox-API-Arg": arg}
                reply = self.transport(DOWNLOAD_URL, headers, None)
            except NotSignedIn:
                raise
            except DropboxError:
                if attempt == ATTEMPTS - 1:
                    raise
                self.sleep(min(60.0, 2.0**attempt))
                continue
            if reply.status == 200:
                try:
                    return self._save(reply, dest)
                except (OSError, http.client.HTTPException) as error:
                    # The connection dropped part way (a reset, IncompleteRead): _save deleted the partial copy.
                    if attempt == ATTEMPTS - 1:
                        raise DropboxError(f"the download of {db_path} kept breaking off "
                                           f"({type(error).__name__})") from None
                    self.sleep(min(60.0, 2.0**attempt))
                    continue
            reply.read_all()
            if reply.status == 401 and not renewed:
                self._access, renewed = None, True
                continue
            if reply.status == 429 or reply.status >= 500:
                if attempt == ATTEMPTS - 1:
                    break
                wait = reply.headers.get("retry-after")
                self.sleep(min(300.0, float(wait)) if wait and wait.isdigit() else min(60.0, 2.0**attempt))
                continue
            raise DropboxError(f"Dropbox would not send {db_path} ({reply.status})")
        raise DropboxError(f"Dropbox was busy for {db_path}; it will be tried again")

    def _save(self, reply: Response, dest: Path) -> int:
        try:
            meta = json.loads(reply.headers.get("dropbox-api-result", "{}"))
        except ValueError:
            meta = {}
        written = 0
        try:
            with open(dest, "wb") as f:
                while True:
                    chunk = reply.body.read(CHUNK)
                    if not chunk:
                        break
                    f.write(chunk)
                    written += len(chunk)
            if "size" in meta and written != int(meta["size"]):
                raise DropboxError(f"the download was cut short ({written} of {meta['size']} bytes)")
            if meta.get("content_hash") and content_hash_of(dest) != meta["content_hash"]:
                raise DropboxError("the download does not match Dropbox's content hash")
        except BaseException:
            dest.unlink(missing_ok=True)
            raise
        return written
