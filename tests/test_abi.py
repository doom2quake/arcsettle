"""The dependency-free ABI layer, pinned to values a reviewer can check elsewhere.

The Keccak vectors are the published ones. The selectors are the ones `solc`
emitted for this repo's contracts; run `forge inspect src/ArcSettlement.sol:ArcSettlement
methodIdentifiers` (and `... errors`) to reproduce the right-hand side.
"""

import pytest

from arcsettle import abi


@pytest.mark.parametrize("message,digest", [
    (b"", "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"),
    (b"abc", "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"),
    (b"testing", "5f16f4c7f149ac4f9510d9cf8cf384038ad348b3bcdc01915f95de12df9d1b02"),
])
def test_keccak256_matches_published_vectors(message, digest):
    assert abi.keccak256(message).hex() == digest


@pytest.mark.parametrize("length,digest", [
    # Exactly the 136-byte rate: the padding-block edge case.
    (136, "a6c4d403279fe3e0af03729caada8374b5ca54d8065329a3ebcaeb4b60aa386e"),
    # Longer than the rate: the multi-block absorb path.
    (200, "96ea54061def936c4be90b518992fdc6f12f535068a256229aca54267b4d084d"),
])
def test_keccak256_block_boundaries(length, digest):
    """Cross-checked against foundry's independent implementation:
    `cast keccak "$(printf 'a%.0s' {1..136})"`."""
    assert abi.keccak256(b"a" * length).hex() == digest


@pytest.mark.parametrize("signature,expected", [
    # ERC-20, verifiable against any block explorer.
    ("totalSupply()", "18160ddd"),
    ("transfer(address,uint256)", "a9059cbb"),
    ("balanceOf(address)", "70a08231"),
    # This repo's contracts, as emitted by solc 0.8.24.
    ("settle(address,uint256)", "15afd409"),
    ("effectiveReserves()", "e7039ed8"),
    ("settleableHeadroom()", "30708cf9"),
    ("redeem(uint256)", "db006a75"),
])
def test_function_selectors_match_solc(signature, expected):
    assert abi.selector(signature).hex() == expected


@pytest.mark.parametrize("signature,expected", [
    ("InsufficientReserves(uint256,uint256)", "5960d221"),
    ("StaleAttestation(uint256,uint256,uint256)", "0ba65e48"),
    ("FutureAttestation(uint256,uint256)", "9904d1f9"),
    ("NotSettler()", "05b94333"),
    ("ZeroAmount()", "1f2a2005"),
    ("ZeroAddress()", "d92e233d"),
])
def test_error_selectors_match_solc(signature, expected):
    """These are what the live dry-run decodes revert data against."""
    assert abi.selector(signature).hex() == expected


def test_uint256_encoding_round_trip():
    assert abi.decode_uint256("0x" + abi.encode_uint256(0).hex()) == 0
    big = abi.UINT256_MAX
    assert abi.decode_uint256("0x" + abi.encode_uint256(big).hex()) == big


@pytest.mark.parametrize("bad", [-1, abi.UINT256_MAX + 1])
def test_uint256_encoding_rejects_out_of_range(bad):
    with pytest.raises(ValueError):
        abi.encode_uint256(bad)


def test_uint256_encoding_rejects_bool():
    with pytest.raises(TypeError):
        abi.encode_uint256(True)


def test_address_encoding_is_left_padded():
    encoded = abi.encode_address("0x00000000000000000000000000000000000000Ab")
    assert len(encoded) == 32
    assert encoded[:12] == bytes(12)
    assert encoded[-1] == 0xAB


@pytest.mark.parametrize("bad", ["0x1234", "not-an-address", "1" * 42, 42, ""])
def test_address_validation_rejects_garbage(bad):
    with pytest.raises(ValueError):
        abi.normalize_address(bad)


def test_decode_rejects_short_return_data():
    with pytest.raises(ValueError):
        abi.decode_uint256("0x1234")
