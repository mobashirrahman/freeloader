import re


def slugify(text, max_length=None):
    if max_length is not None and max_length < 1:
        raise ValueError("max_length must be at least 1")
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    if max_length is not None:
        slug = slug[:max_length].rstrip("-")
    return slug
