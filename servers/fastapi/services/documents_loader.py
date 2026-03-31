import mimetypes
from fastapi import HTTPException
import os, asyncio
from typing import List, Optional, Tuple
import pdfplumber

from constants.documents import (
    MARKDOWN_FILE_EXTENSIONS,
    MARKDOWN_MIME_TYPES,
    PDF_MIME_TYPES,
    POWERPOINT_TYPES,
    TEXT_MIME_TYPES,
    WORD_TYPES,
)


def _strip_optional_yaml_front_matter(text: str) -> str:
    if not text.startswith("---"):
        return text
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return text
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return "\n".join(lines[i + 1 :]).lstrip("\n")
    return text


def _read_markdown_file_sync(file_path: str) -> str:
    with open(file_path, "r", encoding="utf-8", errors="replace") as f:
        raw = f.read()
    return _strip_optional_yaml_front_matter(raw)


class DocumentsLoader:

    def __init__(self, file_paths: List[str]):
        self._file_paths = file_paths

        self._docling_service = None

        self._documents: List[str] = []
        self._images: List[List[str]] = []

    @property
    def docling_service(self):
        if self._docling_service is None:
            from services.docling_service import DoclingService

            self._docling_service = DoclingService()
        return self._docling_service

    @property
    def documents(self):
        return self._documents

    @property
    def images(self):
        return self._images

    async def load_documents(
        self,
        temp_dir: Optional[str] = None,
        load_text: bool = True,
        load_images: bool = False,
    ):
        """If load_images is True, temp_dir must be provided"""

        documents: List[str] = []
        images: List[str] = []

        for file_path in self._file_paths:
            if not os.path.exists(file_path):
                raise HTTPException(
                    status_code=404, detail=f"File {file_path} not found"
                )

            document = ""
            imgs = []

            mime_type = mimetypes.guess_type(file_path)[0]
            path_lower = file_path.lower()
            is_markdown = mime_type in MARKDOWN_MIME_TYPES or path_lower.endswith(
                MARKDOWN_FILE_EXTENSIONS
            )

            if mime_type in PDF_MIME_TYPES:
                document, imgs = await self.load_pdf(
                    file_path, load_text, load_images, temp_dir
                )
            elif is_markdown:
                document = await self.load_markdown(file_path)
            elif mime_type in TEXT_MIME_TYPES:
                document = await self.load_text(file_path)
            elif mime_type in POWERPOINT_TYPES:
                document = self.load_powerpoint(file_path)
            elif mime_type in WORD_TYPES:
                document = self.load_msword(file_path)

            documents.append(document)
            images.append(imgs)

        self._documents = documents
        self._images = images

    async def load_pdf(
        self,
        file_path: str,
        load_text: bool,
        load_images: bool,
        temp_dir: Optional[str] = None,
    ) -> Tuple[str, List[str]]:
        image_paths = []
        document: str = ""

        if load_text:
            document = self.docling_service.parse_to_markdown(file_path)

        if load_images:
            image_paths = await self.get_page_images_from_pdf_async(file_path, temp_dir)

        return document, image_paths

    async def load_text(self, file_path: str) -> str:
        def read_sync() -> str:
            with open(file_path, "r", encoding="utf-8", errors="replace") as file:
                return file.read()

        return await asyncio.to_thread(read_sync)

    async def load_markdown(self, file_path: str) -> str:
        return await asyncio.to_thread(_read_markdown_file_sync, file_path)

    def load_msword(self, file_path: str) -> str:
        return self.docling_service.parse_to_markdown(file_path)

    def load_powerpoint(self, file_path: str) -> str:
        return self.docling_service.parse_to_markdown(file_path)

    @classmethod
    def get_page_images_from_pdf(cls, file_path: str, temp_dir: str) -> List[str]:
        with pdfplumber.open(file_path) as pdf:
            images = []
            for page in pdf.pages:
                img = page.to_image(resolution=150)
                image_path = os.path.join(temp_dir, f"page_{page.page_number}.png")
                img.save(image_path)
                images.append(image_path)
            return images

    @classmethod
    async def get_page_images_from_pdf_async(cls, file_path: str, temp_dir: str):
        return await asyncio.to_thread(
            cls.get_page_images_from_pdf, file_path, temp_dir
        )
