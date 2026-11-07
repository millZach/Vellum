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


def test_the_nearest_of_two_same_named_dwgs_wins():
    near, far = c(f"{P}/CAD/E-201.dwg"), c(f"{P}/Old/Rev A/E-201.dwg")
    pdf = c(f"{P}/CAD/PDF/E-201.pdf")
    assert pairs([pdf], [far, near]) == {pdf.key: (near.key, "name")}


def test_two_equally_near_dwgs_are_told_apart_by_the_pdfs_number_or_not_paired():
    a, b = c(f"{P}/A/E-201.dwg", number="E-201A"), c(f"{P}/B/E-201.dwg", number="E-201B")
    by_number = c(f"{P}/PDF/E-201.pdf", number="E-201B")
    assert pairs([by_number], [a, b]) == {by_number.key: (b.key, "name")}  # not A, which sorts first
    no_number = c(f"{P}/PDF/E-201.pdf")
    assert pairs([no_number], [a, b]) == {}  # can't tell: "PDF only", never a guess
    neither = c(f"{P}/PDF/E-201.pdf", number="E-999")
    assert pairs([neither], [a, b]) == {}
    unknown = c(f"{P}/A/E-201.dwg"), c(f"{P}/B/E-201.dwg")  # neither DWG's number read
    assert pairs([c(f"{P}/PDF/E-201.pdf", number="E-201")], list(unknown)) == {}


def test_a_name_match_whose_numbers_contradict_is_not_a_pair():
    dwg = c(f"{P}/E-201.dwg", number="E-201")
    pdf = c(f"{P}/E-201-1.pdf", number="E-201-1")
    assert pairs([pdf], [dwg]) == {}
    titled = c(f"{P}/set.pdf", number="E-305", title="E-201-Layout1")
    assert pairs([titled], [dwg]) == {}
    agrees = c(f"{P}/E-201-1.pdf", number="E 201")  # same number, written differently
    assert pairs([agrees], [dwg]) == {agrees.key: (dwg.key, "name")}
    unknown = c(f"{P}/E-201-1.pdf")  # no number read from the PDF: nothing contradicts
    assert pairs([unknown], [dwg]) == {unknown.key: (dwg.key, "name")}


def test_a_contradicted_near_dwg_gives_way_to_a_farther_one_that_agrees():
    near = c(f"{P}/CAD/E-201.dwg", number="E-201")
    far = c(f"{P}/Old/Rev A/E-201.dwg", number="E-201X")
    pdf = c(f"{P}/CAD/PDF/E-201.pdf", number="E-201X")
    assert pairs([pdf], [near, far]) == {pdf.key: (far.key, "name")}


def sheet(path, layout, number):
    dwg_key = path.lower()
    return Candidate(f"{dwg_key}#{layout.lower()}", path, FINDER.project_of(path).path, number=number, dwg=dwg_key,
                     layout=layout)


def test_a_pdf_pairs_with_the_layout_it_was_plotted_from():
    e201, e202 = sheet(f"{P}/CAD/Power.dwg", "E-201", "E-201"), sheet(f"{P}/CAD/Power.dwg", "E-202", "E-202")
    by_title = c(f"{P}/PDF/Plot 7.pdf", title="Power-E-202")
    by_name = c(f"{P}/PDF/Power - E-201.pdf")
    by_text = c(f"{P}/PDF/Power.pdf", number="E-202")
    by_number_only = c(f"{P}/Scans/Scan 0042.pdf", number="E 201")
    got = pairs([by_title, by_name, by_text, by_number_only], [e201, e202])
    assert got == {
        by_title.key: (e202.key, "metadata"),
        by_name.key: (e201.key, "name"),
        by_text.key: (e202.key, "name"),
        by_number_only.key: (e201.key, "number"),
    }
    neither = c(f"{P}/PDF/Power.pdf")  # names no layout and has no number: the DWG, but no layout's fields
    assert pairs([neither], [e201, e202]) == {neither.key: (f"{P}/CAD/Power.dwg".lower() + "#*", "name")}


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


def test_a_title_naming_no_layout_falls_back_to_the_file_name_and_never_guesses_a_layout():
    e201, e202 = sheet(f"{P}/CAD/Power.dwg", "E-201", "E-201"), sheet(f"{P}/CAD/Power.dwg", "E-202", "E-202")
    by_file_name = c(f"{P}/PDF/Power-E-202.pdf", title="Power")  # the title names the DWG only; no number read
    assert pairs([by_file_name], [e201, e202]) == {by_file_name.key: (e202.key, "metadata")}
    by_number = c(f"{P}/PDF/Power.pdf", title="Power", number="E-202")
    assert pairs([by_number], [e201, e202]) == {by_number.key: (e202.key, "metadata")}
    nothing = c(f"{P}/PDF/Power issued.pdf", title="Power")  # no layout named anywhere, no number
    dwg_only = f"{P}/CAD/Power.dwg".lower() + "#*"
    assert pairs([nothing], [e201, e202]) == {nothing.key: (dwg_only, "metadata")}  # the DWG, no layout's fields
