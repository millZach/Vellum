import pytest

from vellum_indexer.projects import NO_PROJECT, Project, ProjectFinder


@pytest.mark.parametrize(
    "path, project",
    [
        # under the projects root: its top folder
        ("/Projects/Made-up Plant Upgrade/Electrical/DWG/E-201.dwg", ("Made-up Plant Upgrade", "/Projects/Made-up Plant Upgrade")),
        ("/projects/Made-up School/M-101.pdf", ("Made-up School", "/projects/Made-up School")),
        ("/Projects/Made-up School/Phase 2/Mech/M-101.dwg", ("Made-up School", "/Projects/Made-up School")),
        # elsewhere: the folder holding the discipline and format folders
        ("/Clients/Made-up Mill/Boiler 4/Mechanical/PDF/M-501.pdf", ("Boiler 4", "/Clients/Made-up Mill/Boiler 4")),
        ("/Jobs/2026-014 Made-up Dam/CAD/Rev C/C-002.dwg", ("2026-014 Made-up Dam", "/Jobs/2026-014 Made-up Dam")),
        ("/Jobs/Made-up Dam/IFC Set/E-1.pdf", ("Made-up Dam", "/Jobs/Made-up Dam")),
        ("/Vendor/Made-up Pumps/V-12.pdf", ("Made-up Pumps", "/Vendor/Made-up Pumps")),
        # only discipline folders above: the top folder
        ("/Drawings/PDF/E-1.pdf", ("Drawings", "/Drawings")),
        ("/Projects/E-1.pdf", ("Projects", "/Projects")),
    ],
)
def test_project_of(path, project):
    assert ProjectFinder().project_of(path) == Project(*project)


def test_a_drawing_at_the_top_of_dropbox_has_no_project():
    assert ProjectFinder().project_of("/E-1.pdf") == NO_PROJECT


def test_settings_name_other_projects_roots():
    finder = ProjectFinder(["/Work/Active", "Clients"])
    assert finder.project_of("/Work/Active/Made-up Job/Mechanical/M-1.dwg") == Project("Made-up Job", "/Work/Active/Made-up Job")
    assert finder.project_of("/Clients/Made-up Mill/Boiler 4/M-1.dwg") == Project("Made-up Mill", "/Clients/Made-up Mill")
    # no longer a root: found by the walk-up
    assert finder.project_of("/Projects/Made-up School/PDF/M-1.pdf") == Project("Made-up School", "/Projects/Made-up School")
