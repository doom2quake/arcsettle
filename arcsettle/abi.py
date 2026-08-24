"""Minimal, dependency-free ABI helpers: Keccak-256, selectors, uint/address codecs.

ArcSettle's live mode talks to an Arc testnet node over plain JSON-RPC. That needs
exactly three things from an ABI library: Keccak-256 (for 4-byte selectors), 32-byte
word encoding, and 32-byte word decoding. All three are here, in about a hundred
lines, so the live path has no install-time dependency that could turn "live mode"
into an import error.

Selectors are COMPUTED from their signatures, never pasted, so a reviewer can check
them against an Arc block explorer. `tests/test_abi.py` pins the Keccak implementation
to published vectors and pins `totalSupply()` to its well-known selector 0x18160ddd.
"""

from __future__ import annotations

_MASK = (1 << 64) - 1

_ROUND_CONSTANTS = (
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
)

_ROTATIONS = (
    (0, 36, 3, 41, 18),
    (1, 44, 10, 45, 2),
    (62, 6, 43, 15, 61),
    (28, 55, 25, 21, 56),
    (27, 20, 39, 8, 14),
)

_RATE = 136  # bytes absorbed per permutation for Keccak-256 (1600 - 2*256)/8


def _rol(value: int, shift: int) -> int:
    return ((value << shift) | (value >> (64 - shift))) & _MASK if shift else value


def _keccak_f(a: list[list[int]]) -> list[list[int]]:
    for rc in _ROUND_CONSTANTS:
        # theta
        c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
        for x in range(5):
            for y in range(5):
                a[x][y] ^= d[x]
        # rho + pi
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                b[y][(2 * x + 3 * y) % 5] = _rol(a[x][y], _ROTATIONS[x][y])
        # chi
        for x in range(5):
            for y in range(5):
                a[x][y] = b[x][y] ^ ((~b[(x + 1) % 5][y] & _MASK) & b[(x + 2) % 5][y])
        # iota
        a[0][0] ^= rc
    return a


def keccak256(data: bytes) -> bytes:
    """Keccak-256 (the Ethereum hash, i.e. original padding, not NIST SHA3-256)."""
    state = [[0] * 5 for _ in range(5)]
    msg = bytearray(data)
    pad_len = _RATE - (len(msg) % _RATE)
    msg += b"\x01" + b"\x00" * (pad_len - 1)
    msg[-1] ^= 0x80
    for offset in range(0, len(msg), _RATE):
        block = msg[offset:offset + _RATE]
        for i in range(_RATE // 8):
            state[i % 5][i // 5] ^= int.from_bytes(block[i * 8:i * 8 + 8], "little")
        state = _keccak_f(state)
    out = bytearray()
    for i in range(4):  # 4 lanes * 8 bytes = 32 bytes
        out += state[i % 5][i // 5].to_bytes(8, "little")
    return bytes(out)


def selector(signature: str) -> bytes:
    """4-byte function/error selector for a canonical signature, e.g. `totalSupply()`."""
    return keccak256(signature.encode("ascii"))[:4]


UINT256_MAX = (1 << 256) - 1


def encode_uint256(value: int) -> bytes:
    if not isinstance(value, int) or isinstance(value, bool):
        raise TypeError(f"uint256 must be an int, got {type(value).__name__}")
    if value < 0 or value > UINT256_MAX:
        raise ValueError(f"value out of uint256 range: {value}")
    return value.to_bytes(32, "big")


def encode_address(address: str) -> bytes:
    return bytes(12) + bytes.fromhex(normalize_address(address)[2:])


def normalize_address(address: str) -> str:
    """Lowercase 0x-prefixed 20-byte address, or raise ValueError."""
    if not isinstance(address, str):
        raise ValueError(f"address must be a string, got {type(address).__name__}")
    a = address.strip().lower()
    if not a.startswith("0x") or len(a) != 42:
        raise ValueError(f"not a 20-byte 0x address: {address!r}")
    try:
        bytes.fromhex(a[2:])
    except ValueError as exc:
        raise ValueError(f"not a 20-byte 0x address: {address!r}") from exc
    return a


def decode_uint256(hex_result: str) -> int:
    """Decode a single uint256 return word from an `eth_call` result."""
    raw = hex_result[2:] if hex_result.startswith("0x") else hex_result
    if len(raw) < 64:
        raise ValueError(f"eth_call returned {len(raw) // 2} bytes, expected >= 32")
    return int(raw[:64], 16)
