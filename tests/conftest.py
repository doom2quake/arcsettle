"""Test fixtures.

The audit store is forced in-memory here rather than in a README instruction, so
`pytest tests -q` works on a clean machine with no GCP credentials and no env vars.
This is set before `arcsettle` is imported anywhere.
"""

import os

os.environ.setdefault("ARC_IN_MEMORY_STATE", "true")
os.environ.setdefault("GOOGLE_CLOUD_PROJECT", "arcsettle-tests")
# Keep the agent offline unless a test explicitly builds live settings.
os.environ.pop("ARC_RPC_URL", None)
os.environ.pop("ARC_SETTLEMENT_ADDRESS", None)

import pytest  # noqa: E402

from arcsettle import chain, main  # noqa: E402


@pytest.fixture(autouse=True)
def _clean_state():
    chain._reset()
    main._reset_store_for_tests()
    main._limiter._recent.clear()
    main._limiter._cycle_counts.clear()
    yield
    chain._reset()
    main._reset_store_for_tests()
