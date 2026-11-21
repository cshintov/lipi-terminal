"""Select or clone a complete Lipi profile in memory, never read/write preferences."""
from copy import deepcopy
from uuid import uuid4

SCROLL_KEYS = (
    'Mouse Reporting',
    'Mouse Reporting allow mouse wheel',
    'Scrollback in Alternate Screen',
    'Allow Alternate Mouse Scroll',
    'Automatically Enable Alternate Mouse Scroll',
)


def profile_for_launch(profiles, name, source_name='Lipi Terminal Test'):
    """Reuse the named profile, otherwise clone the whole known test profile.

    Caller supplies resolved scroll defaults and owns persistence.
    All five scroll settings are preserved exactly.
    Refuse broken/ambiguous input rather than silently changing mouse behavior.
    """
    selected = [p for p in profiles if p.get('Name') == name]
    existing = bool(selected)
    if not existing:
        selected = [p for p in profiles if p.get('Name') == source_name]
    if len(selected) != 1 or not selected[0].get('Guid'):
        raise ValueError('Exactly one named profile with a Guid is required')
    source = selected[0]
    if any(key not in source for key in SCROLL_KEYS):
        raise ValueError('Profile must explicitly include all five scroll settings')
    if any(source[key] != True for key in SCROLL_KEYS[:2]):
        raise ValueError('Mouse reporting and mouse wheel reporting must be enabled')
    result = deepcopy(source)
    if not existing:
        result.update(Name=name, Guid=str(uuid4()).upper())
    return result
