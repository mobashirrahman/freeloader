Add a URL slug helper to shopkit, with tests.

Create `shopkit/text.py` with one function, `slugify(text: str, max_length: int | None = None) -> str`:

- Lowercase the text.
- Replace every run of characters that are not `a-z` or `0-9` with a single `-`.
- Strip leading and trailing `-`.
- If `max_length` is given, cut the result to at most that many characters, and never leave a trailing `-` after cutting.
- `max_length` below 1 raises `ValueError`.
- Text with no letters or digits gives `""`.
