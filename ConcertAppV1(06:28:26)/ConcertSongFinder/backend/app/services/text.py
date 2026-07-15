import re
import unicodedata


def normalize_title(value: str) -> str:
    value = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode("ascii")
    value = value.lower()
    value = re.sub(r"[^a-z0-9]+", " ", value)
    value = re.sub(r"\s+", " ", value).strip()
    for suffix in (" remastered", " remaster", " explicit", " deluxe edition", " radio edit", " album version"):
        if value.endswith(suffix):
            value = value[: -len(suffix)].strip()
    return value
