from notion_client import Client
from typing import List, Optional

class NotionNoteManager:
    def __init__(self, token: str, parent_page_id: str):
        self.notion = Client(auth=token)
        self.parent_page_id = parent_page_id

    # -----------------------------
    # Core Functions
    # -----------------------------

    def read_file_structure(self):
        """List all child pages under the parent page."""
        children = self.notion.blocks.children.list(self.parent_page_id)
        structure = []
        for child in children.get("results", []):
            if child["type"] == "child_page":
                structure.append({
                    "id": child["id"],
                    "title": child["child_page"]["title"]
                })
        return structure

    def read_note(self, page_id: str) -> str:
        """Read all paragraph text from a given page."""
        blocks = self.notion.blocks.children.list(page_id)
        content = []
        for block in blocks.get("results", []):
            if block["type"] == "paragraph":
                text_items = block["paragraph"]["rich_text"]
                content.extend([t["plain_text"] for t in text_items])
        return "\n".join(content)

    def create_note(self, title: str, content: str):
        """Create a new note (page) under the parent."""
        page = self.notion.pages.create(
            parent={"type": "page_id", "page_id": self.parent_page_id},
            properties={
                "title": [{"type": "text", "text": {"content": title}}],
            },
        )

        page_id = page["id"]

        # Add initial content
        self.notion.blocks.children.append(
            page_id,
            children=[{
                "object": "block",
                "type": "paragraph",
                "paragraph": {
                    "rich_text": [{"type": "text", "text": {"content": content}}],
                },
            }]
        )

        return page["url"]

    def modify_note(self, page_id: str, new_content: str):
        """Replace the note’s content with new text."""
        # Clear existing blocks (optional)
        blocks = self.notion.blocks.children.list(page_id)
        for b in blocks.get("results", []):
            self.notion.blocks.delete(b["id"])

        # Add new content
        self.notion.blocks.children.append(
            page_id,
            children=[{
                "object": "block",
                "type": "paragraph",
                "paragraph": {
                    "rich_text": [{"type": "text", "text": {"content": new_content}}],
                },
            }]
        )
        return f"✅ Note {page_id} updated."

    def search_notes(self, query: str):
        """Perform plain-text search across workspace."""
        results = self.notion.search(query=query)
        notes = []
        for r in results.get("results", []):
            if r["object"] == "page":
                notes.append({
                    "id": r["id"],
                    "title": r["properties"]["title"]["title"][0]["plain_text"]
                    if "title" in r["properties"] and r["properties"]["title"]["title"]
                    else "Untitled",
                    "url": r["url"]
                })
        return notes

    def find_page_by_title(self, parent_id: str, title: str) -> Optional[str]:
        """Find a child page by title within a parent page. Returns page_id if found, None otherwise."""
        children = self.notion.blocks.children.list(parent_id)
        for child in children.get("results", []):
            if child["type"] == "child_page":
                child_title = child["child_page"]["title"]
                if child_title == title:
                    return child["id"]
        return None

    def append_to_note(self, page_id: str, content: str):
        """Append content to an existing note."""
        self.notion.blocks.children.append(
            page_id,
            children=[{
                "object": "block",
                "type": "paragraph",
                "paragraph": {
                    "rich_text": [{"type": "text", "text": {"content": content}}],
                },
            }]
        )

    def find_root_page_by_title(self, title: str) -> Optional[str]:
        """Find a root page by title using search. Returns page_id if found, None otherwise."""
        results = self.notion.search(query=title)
        for r in results.get("results", []):
            if r["object"] == "page":
                page_title = r["properties"]["title"]["title"][0]["plain_text"] if "title" in r["properties"] and r["properties"]["title"]["title"] else "Untitled"
                if page_title == title:
                    return r["id"]
        return None

    def create_page_under_parent(self, parent_id: str, title: str, content: str = ""):
        """Create a new page under a parent page."""
        page = self.notion.pages.create(
            parent={"type": "page_id", "page_id": parent_id},
            properties={
                "title": [{"type": "text", "text": {"content": title}}],
            },
        )
        page_id = page["id"]
        
        if content:
            self.notion.blocks.children.append(
                page_id,
                children=[{
                    "object": "block",
                    "type": "paragraph",
                    "paragraph": {
                        "rich_text": [{"type": "text", "text": {"content": content}}],
                    },
                }]
            )
        
        return page_id

    def find_root_level_page(self) -> Optional[str]:
        """Find any root-level page to use as a parent. Returns page_id if found, None otherwise."""
        # Search for pages and find one that appears to be root-level
        # Root pages typically don't have a parent_id in their parent field
        results = self.notion.search()
        for r in results.get("results", []):
            if r["object"] == "page":
                parent = r.get("parent", {})
                # Check if it's a workspace-level page (no page_id parent)
                if parent.get("type") != "page_id":
                    return r["id"]
        return None

    def create_root_page(self, title: str, fallback_parent_id: Optional[str] = None, content: str = ""):
        """
        Create a new page. Since Notion API doesn't support workspace root creation,
        this will try to find a root-level page to use as parent, or use fallback_parent_id.
        """
        # Try to find a root-level page to use as parent
        parent_id = self.find_root_level_page()
        
        if parent_id is None:
            if fallback_parent_id:
                parent_id = fallback_parent_id
            else:
                raise ValueError(
                    "Cannot create root page: No root-level page found to use as parent. "
                    "Please create 'DigitalVault' manually in Notion, or provide a fallback_parent_id."
                )
        
        page = self.notion.pages.create(
            parent={"type": "page_id", "page_id": parent_id},
            properties={
                "title": [{"type": "text", "text": {"content": title}}],
            },
        )
        page_id = page["id"]
        
        if content:
            self.notion.blocks.children.append(
                page_id,
                children=[{
                    "object": "block",
                    "type": "paragraph",
                    "paragraph": {
                        "rich_text": [{"type": "text", "text": {"content": content}}],
                    },
                }]
            )
        
        return page_id
