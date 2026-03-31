import asyncio
import os
import tempfile
import zipfile

from models.pptx_models import (
    PptxChartBoxModel,
    PptxChartSeriesModel,
    PptxPositionModel,
    PptxPresentationModel,
    PptxSlideModel,
    PptxTableBoxModel,
)
from services.pptx_presentation_creator import PptxPresentationCreator


def test_native_table_and_chart_export():
    ppt_model = PptxPresentationModel(
        slides=[
            PptxSlideModel(
                shapes=[
                    PptxTableBoxModel(
                        position=PptxPositionModel(
                            left=50, top=50, width=400, height=200
                        ),
                        columns=["A", "B"],
                        rows=[["1", "2"], ["3", "4"]],
                    ),
                    PptxChartBoxModel(
                        position=PptxPositionModel(
                            left=500, top=50, width=700, height=350
                        ),
                        chart_type="bar",
                        categories=["Jan", "Feb", "Mar"],
                        series=[
                            PptxChartSeriesModel(
                                name="Series 1", values=[10, 20, 15]
                            )
                        ],
                        showLegend=True,
                    ),
                ]
            )
        ]
    )

    with tempfile.TemporaryDirectory() as tmpdir:
        creator = PptxPresentationCreator(ppt_model, tmpdir)
        asyncio.run(creator.create_ppt())

        out_path = os.path.join(tmpdir, "native_table_chart.pptx")
        creator.save(out_path)

        assert os.path.exists(out_path)
        assert os.path.getsize(out_path) > 0

        with zipfile.ZipFile(out_path, "r") as zf:
            names = zf.namelist()

            # Chart pieces are typically extracted into ppt/charts/chart*.xml
            assert any(
                name.startswith("ppt/charts/chart") and name.endswith(".xml")
                for name in names
            ), f"Missing chart xml, got: {names[:20]}"

            # Table is stored in slide xml as a:t ble element ("a:tbl" in drawingml).
            slide_xml_candidates = [
                name
                for name in names
                if name.startswith("ppt/slides/") and name.endswith(".xml")
            ]
            assert slide_xml_candidates, "Missing slide xml entries"

            slide_xml = zf.read(slide_xml_candidates[0]).decode(
                "utf-8", errors="ignore"
            )
            assert "a:tbl" in slide_xml, "Missing native table xml (a:tbl)"

