from pathlib import Path

from vellum_indexer import fields
from vellum_indexer.dwg import BlockInsert
from vellum_indexer.fields import TagMap, TitleBlock, from_attributes, from_pdf_text, number_from_file_name
from vellum_indexer.pdf import read_pdf

from makers import DxfReader, make_dxf, title_block_pdf


def test_attributes_from_a_made_up_dwg_title_block(tmp_path: Path):
    dwg = make_dxf(tmp_path / "M-101.dwg", [
        ("Layout1", {"DWG_NO": "M-101", "TITLE": "First floor HVAC plan", "REV": "C",
                     "SCALE": '1/4" = 1\'-0"', "DATE": "2026-10-12", "DRAWN_BY": "ZM"}),
    ])
    block = from_attributes(DxfReader().read(dwg))
    assert block == TitleBlock("M-101", "First floor HVAC plan", "C", '1/4" = 1\'-0"', "2026-10-12")


def test_the_title_block_is_the_insert_naming_most_fields_paper_space_first():
    inserts = [
        BlockInsert("Model", "TAG", {"TAG": "FT-101"}),
        BlockInsert("Model", "TB", {"DWGNO": "X-1", "TITLE": "Model space copy", "REV": "0"}),
        BlockInsert("Layout1", "REVROW", {"REV": "B", "DATE": "2026-01-01"}),
        BlockInsert("Layout1", "TB", {"DWGNO": "E-201", "TITLE": "Boiler room power plan", "REV": "A"}),
    ]
    block = from_attributes(inserts)
    assert (block.number, block.title, block.revision, block.date) == ("E-201", "Boiler room power plan", "A", None)


def test_title_lines_are_joined_in_order_and_blank_or_unevaluated_values_are_none():
    inserts = [BlockInsert("A1", "TB", {
        "TITLE_LINE_2": "PUMP SKID", "TITLE_LINE_1": "MADE-UP PLANT", "TITLE_LINE_3": "GENERAL ARRANGEMENT",
        "DWG-NO": "I-301", "REV": "####", "SCALE": "--", "DATE": "  ",
    })]
    block = from_attributes(inserts)
    assert block == TitleBlock("I-301", "MADE-UP PLANT PUMP SKID GENERAL ARRANGEMENT", None, None, None)


def test_settings_can_name_more_tags():
    inserts = [BlockInsert("Layout1", "TB", {"SHT_ID": "C-002", "HEADING": "Site grading"})]
    assert from_attributes(inserts).number is None
    tags = TagMap({"number": ["SHT_ID"], "title": ["HEADING"]})
    assert from_attributes(inserts, tags) == TitleBlock("C-002", "Site grading")


def test_no_attributes_means_no_fields():
    assert not from_attributes([]).any()
    assert not from_attributes([BlockInsert("Layout1", "NORTH", {"ARROW": "N"})]).any()


def test_pdf_text_fallback_reads_labels_with_values_beside_or_below():
    text = "\n".join([
        "MADE-UP ENGINEERING CO.",
        "DRAWING TITLE",
        "Pump skid general arrangement",
        "DWG NO. V-12",
        "REVISIONS",
        "REV: 2",
        "SCALE 1:20",
        "DATE",
        "2026-09-30",
    ])
    assert from_pdf_text(text) == TitleBlock("V-12", "Pump skid general arrangement", "2", "1:20", "2026-09-30")


def test_pdf_text_fallback_refuses_values_that_are_not_that_field():
    text = "\n".join(["SCALE", "SEE PLAN", "REV", "REVISED PER COMMENTS", "DATE", "TBD", "DWG NO", "DRAWN BY"])
    assert from_pdf_text(text) == TitleBlock()


def test_pdf_text_from_a_made_up_title_block_pdf(tmp_path: Path):
    pdf = title_block_pdf(tmp_path / "x.pdf", number="M-501", title="Mechanical details", rev="B",
                          scale="AS NOTED", date="2026-10-01")
    block = from_pdf_text(read_pdf(pdf).text)
    assert block == TitleBlock("M-501", "Mechanical details", "B", "AS NOTED", "2026-10-01")


def test_drawing_number_from_a_file_name_that_looks_like_one():
    assert number_from_file_name("M-101") == "M-101"
    assert number_from_file_name("e201a") == "E201A"
    assert number_from_file_name("I-301.2") == "I-301.2"
    assert number_from_file_name("Pump skid GA") is None
    assert number_from_file_name("M-101 - Layout1") is None


def test_tags_compare_without_punctuation_or_case():
    assert fields.norm_tag("Dwg_No.") == "DWGNO"
    assert TagMap().field_of("dwg-no") == "number"
