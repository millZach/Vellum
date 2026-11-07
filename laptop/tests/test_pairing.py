from vellum_indexer.pairing import Candidate, Pairing, pair
from vellum_indexer.projects import ProjectFinder

FINDER = ProjectFinder()


def c(path, number=None, title=None):
    return Candidate(path.lower(), path, FINDER.project_of(path).path, number=number, meta_title=title)


def pairs(pdfs, dwgs):
    return {k: (p.dwg_key, p.rule) for k, p in pair(pdfs, dwgs).items()}


P = "/Projects/Made-up Plant"


def test_same_name_in_the_same_folder():
    assert pairs([c(f"{P}/E-201.pdf")], [c(f"{P}/E-201.dwg")]) == {f"{P}/e-201.pdf".lower(): (f"{P}/e-201.dwg".lower(), "name")}


def test_same_name_in_a_pdf_or_plots_folder_beside_or_under_the_dwg():
    dwgs = [c(f"{P}/CAD/E-201.dwg"), c(f"{P}/CAD/E-202.dwg")]
    pdfs = [c(f"{P}/PDF/E-201.pdf"), c(f"{P}/CAD/Plots/E-202.pdf")]
    got = pairs(pdfs, dwgs)
    assert got[pdfs[0].key] == (dwgs[0].key, "name")
    assert got[pdfs[1].key] == (dwgs[1].key, "name")


def test_cousin_folders_two_up_and_two_down():
    dwg = c(f"{P}/CAD/Electrical/E-201.dwg")
    pdf = c(f"{P}/PDF/Electrical/E-201.pdf")
    assert pairs([pdf], [dwg]) == {pdf.key: (dwg.key, "name")}


def test_too_far_apart_or_in_another_project_does_not_pair():
    far = c(f"{P}/A/B/C/E-201.pdf")
    dwg = c(f"{P}/X/Y/E-201.dwg")
    other_project = c("/Projects/Made-up School/E-201.pdf")
    assert pairs([far, other_project], [dwg]) == {}


def test_a_name_with_a_layout_or_revision_suffix():
    dwg = c(f"{P}/E-201.dwg")
    pdfs = [c(f"{P}/E-201 - Layout1.pdf"), c(f"{P}/E-201-Model.pdf"), c(f"{P}/E-201_Rev C.pdf"), c(f"{P}/E-201 IFC.pdf")]
    assert {k: v for k, v in pairs(pdfs, [dwg]).items()} == {p.key: (dwg.key, "name") for p in pdfs}


def test_the_longest_stem_wins_and_a_prefix_without_a_separator_does_not_match():
    short, long = c(f"{P}/E-2.dwg"), c(f"{P}/E-2-1.dwg")
    got = pairs([c(f"{P}/E-2-1.pdf"), c(f"{P}/E-21.pdf"), c(f"{P}/E-2-1 - Layout1.pdf")], [short, long])
    assert got == {
        f"{P}/e-2-1.pdf".lower(): (long.key, "name"),
        f"{P}/e-2-1 - layout1.pdf".lower(): (long.key, "name"),
    }


def test_plot_metadata_names_the_dwg_even_when_the_pdf_was_renamed():
    dwg = c(f"{P}/CAD/E-201.dwg")
    pdf = c(f"{P}/PDF/Issued for construction set 3.pdf", title="E-201-Layout1")
    assert pairs([pdf], [dwg]) == {pdf.key: (dwg.key, "metadata")}
    pdf2 = c(f"{P}/PDF/set.pdf", title="E-201.dwg - Sheet 1")
    assert pairs([pdf2], [dwg]) == {pdf2.key: (dwg.key, "metadata")}


def test_metadata_beats_the_name():
    by_name, by_title = c(f"{P}/E-201.dwg"), c(f"{P}/E-201B.dwg")
    pdf = c(f"{P}/E-201.pdf", title="E-201B - Layout1")
    assert pairs([pdf], [by_name, by_title]) == {pdf.key: (by_title.key, "metadata")}


def test_metadata_naming_no_nearby_dwg_falls_through_to_the_name():
    dwg = c(f"{P}/E-201.dwg")
    pdf = c(f"{P}/E-201.pdf", title="Microsoft Word - spec.docx")
    assert pairs([pdf], [dwg]) == {pdf.key: (dwg.key, "name")}


def test_the_nearest_of_two_same_named_dwgs_wins_then_the_first_by_path():
    near, far = c(f"{P}/CAD/E-201.dwg"), c(f"{P}/Old/Rev A/E-201.dwg")
    pdf = c(f"{P}/CAD/PDF/E-201.pdf")
    assert pairs([pdf], [far, near]) == {pdf.key: (near.key, "name")}
    a, b = c(f"{P}/A/E-201.dwg"), c(f"{P}/B/E-201.dwg")
    pdf2 = c(f"{P}/PDF/E-201.pdf")
    assert pairs([pdf2], [b, a]) == {pdf2.key: (a.key, "name")}


def test_same_drawing_number_in_the_same_project_when_only_one_dwg_has_it():
    dwg = c(f"{P}/CAD/Power plan.dwg", number="E-201")
    pdf = c(f"{P}/Submittals/2026/Scan 0042.pdf", number="E 201")
    assert pairs([pdf], [dwg]) == {pdf.key: (dwg.key, "number")}
    twin = c(f"{P}/CAD/Power plan copy.dwg", number="E-201")
    assert pairs([pdf], [dwg, twin]) == {}
    elsewhere = c("/Projects/Made-up School/Scan.pdf", number="E-201")
    assert pairs([elsewhere], [dwg]) == {}


def test_a_vendor_pdf_with_no_dwg_is_not_paired():
    assert pairs([c(f"{P}/Vendor/V-12 Pump skid GA.pdf", number="V-12")], [c(f"{P}/E-201.dwg", number="E-201")]) == {}


def test_names_compare_without_case():
    dwg = c(f"{P}/e-201.DWG")
    pdf = c(f"{P}/E-201.PDF")
    assert pair([pdf], [dwg]) == {pdf.key: Pairing(dwg.key, "name")}
