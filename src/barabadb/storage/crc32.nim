## CRC32 — IEEE 802.3 (Ethernet, ZIP, PNG)
## Zero-dependency implementation for SSTable and WAL integrity checks.
import std/strutils
##
## Polynomial: 0xEDB88320
## Initial:    0xFFFFFFFF
## Final XOR:  0xFFFFFFFF

const CRC32_TABLE: array[256, uint32] = [
  0x00000000'u32, 0x77073096'u32, 0xee0e612c'u32, 0x990951ba'u32,
  0x076dc419'u32, 0x706af48f'u32, 0xe963a535'u32, 0x9e6495a3'u32,
  0x0edb8832'u32, 0x79dcb8a4'u32, 0xe0d5e91e'u32, 0x97d2d988'u32,
  0x09b64c2b'u32, 0x7eb17cbd'u32, 0xe7b82d07'u32, 0x90bf1d91'u32,
  0x1db71064'u32, 0x6ab020f2'u32, 0xf3b97148'u32, 0x84be41de'u32,
  0x1adad47d'u32, 0x6ddde4eb'u32, 0xf4d4b551'u32, 0x83d385c7'u32,
  0x136c9856'u32, 0x646ba8c0'u32, 0xfd62f97a'u32, 0x8a65c9ec'u32,
  0x14015c4f'u32, 0x63066cd9'u32, 0xfa0f3d63'u32, 0x8d080df5'u32,
  0x3b6e20c8'u32, 0x4c69105e'u32, 0xd56041e4'u32, 0xa2677172'u32,
  0x3c03e4d1'u32, 0x4b04d447'u32, 0xd20d85fd'u32, 0xa50ab56b'u32,
  0x35b5a8fa'u32, 0x42b2986c'u32, 0xdbbbc9d6'u32, 0xacbcf940'u32,
  0x32d86ce3'u32, 0x45df5c75'u32, 0xdcd60dcf'u32, 0xabd13d59'u32,
  0x26d930ac'u32, 0x51de003a'u32, 0xc8d75180'u32, 0xbfd06116'u32,
  0x21b4f4b5'u32, 0x56b3c423'u32, 0xcfba9599'u32, 0xb8bda50f'u32,
  0x2802b89e'u32, 0x5f058808'u32, 0xc60cd9b2'u32, 0xb10be924'u32,
  0x2f6f7c87'u32, 0x58684c11'u32, 0xc1611dab'u32, 0xb6662d3d'u32,
  0x76dc4190'u32, 0x01db7106'u32, 0x98d220bc'u32, 0xefd5102a'u32,
  0x71b18589'u32, 0x06b6b51f'u32, 0x9fbfe4a5'u32, 0xe8b8d433'u32,
  0x7807c9a2'u32, 0x0f00f934'u32, 0x9609a88e'u32, 0xe10e9818'u32,
  0x7f6a0dbb'u32, 0x086d3d2d'u32, 0x91646c97'u32, 0xe6630c01'u32,
  0x6b6b51f4'u32, 0x1c6c6162'u32, 0x856530d8'u32, 0xf262004e'u32,
  0x6c0695ed'u32, 0x1b01a57b'u32, 0x8208f4c1'u32, 0xf50fc457'u32,
  0x65b0d9c6'u32, 0x12b7e950'u32, 0x8bbeb8ea'u32, 0xfcb9887c'u32,
  0x62dd1ddf'u32, 0x15da2d49'u32, 0x8cd37cf3'u32, 0xfbd44c65'u32,
  0x4db26158'u32, 0x3ab551ce'u32, 0xa3bc0074'u32, 0xd4bb30e2'u32,
  0x4adfa541'u32, 0x3dd895d7'u32, 0xa4d1c46d'u32, 0xd3d6f4fb'u32,
  0x4369e96a'u32, 0x346ed9fc'u32, 0xad678846'u32, 0xda60b8d0'u32,
  0x44042d73'u32, 0x33031de5'u32, 0xaa0a4c5f'u32, 0xdd0d7cc9'u32,
  0x5005713c'u32, 0x270241aa'u32, 0xbe0b1010'u32, 0xc90c2086'u32,
  0x5768b525'u32, 0x206f85b3'u32, 0xb966d409'u32, 0xce61e49f'u32,
  0x5edef90e'u32, 0x29d9c998'u32, 0xb0d09822'u32, 0xc7d7a8b4'u32,
  0x59b33d17'u32, 0x2eb40d81'u32, 0xb7bd5c3b'u32, 0xc0ba6cad'u32,
  0xedb88320'u32, 0x9abfb3b6'u32, 0x03b6e20c'u32, 0x74b1d29a'u32,
  0xead54739'u32, 0x9dd277af'u32, 0x04db2615'u32, 0x73dc1683'u32,
  0xe3630b12'u32, 0x94643b84'u32, 0x0d6d6a3e'u32, 0x7a6a5aa8'u32,
  0xe40ecf0b'u32, 0x9309ff9d'u32, 0x0a00ae27'u32, 0x7d079eb1'u32,
  0xf00f9344'u32, 0x8708a3d2'u32, 0x1e01f268'u32, 0x6906c2fe'u32,
  0xf762575d'u32, 0x806567cb'u32, 0x196c3671'u32, 0x6e6b06e7'u32,
  0xfed41b76'u32, 0x89d32be0'u32, 0x10da7a5a'u32, 0x67dd4acc'u32,
  0xf9b9df6f'u32, 0x8ebeeff9'u32, 0x17b7be43'u32, 0x60b08ed5'u32,
  0xd6d6a3e8'u32, 0xa1d1937e'u32, 0x38d8c2c4'u32, 0x4fdff252'u32,
  0xd1bb67f1'u32, 0xa6bc5767'u32, 0x3fb506dd'u32, 0x48b2364b'u32,
  0xd80d2bda'u32, 0xaf0a1b4c'u32, 0x36034af6'u32, 0x41047a60'u32,
  0xdf60efc3'u32, 0xa867df55'u32, 0x316e8eef'u32, 0x4669be79'u32,
  0xcb61b38c'u32, 0xbc66831a'u32, 0x256fd2a0'u32, 0x5268e236'u32,
  0xcc0c7795'u32, 0xbb0b4703'u32, 0x220216b9'u32, 0x5505262f'u32,
  0xc5ba3bbe'u32, 0xb2bd0b28'u32, 0x2bb45a92'u32, 0x5cb36a04'u32,
  0xc2d7ffa7'u32, 0xb5d0cf31'u32, 0x2cd99e8b'u32, 0x5bdeae1d'u32,
  0x9b64c2b0'u32, 0xec63f226'u32, 0x756aa39c'u32, 0x026d930a'u32,
  0x9c0906a9'u32, 0xeb0e363f'u32, 0x72076785'u32, 0x05005713'u32,
  0x95bf4a82'u32, 0xe2b87a14'u32, 0x7bb12bae'u32, 0x0cb61b38'u32,
  0x92d28e9b'u32, 0xe5d5be0d'u32, 0x7cdcefb7'u32, 0x0bdbdf21'u32,
  0x86d3d2d4'u32, 0xf1d4e242'u32, 0x68ddb3f8'u32, 0x1fda836e'u32,
  0x81be16cd'u32, 0xf6b9265b'u32, 0x6fb077e1'u32, 0x18b74777'u32,
  0x88085ae6'u32, 0xff0f6a70'u32, 0x66063bca'u32, 0x11010b5c'u32,
  0x8f659eff'u32, 0xf862ae69'u32, 0x616bffd3'u32, 0x166ccf45'u32,
  0xa00ae278'u32, 0xd70dd2ee'u32, 0x4e048354'u32, 0x3903b3c2'u32,
  0xa7672661'u32, 0xd06016f7'u32, 0x4969474d'u32, 0x3e6e77db'u32,
  0xaed16a4a'u32, 0xd9d65adc'u32, 0x40df0b66'u32, 0x37d83bf0'u32,
  0xa9bcae53'u32, 0xdebb9ec5'u32, 0x47b2cf7f'u32, 0x30b5ffe9'u32,
  0xbdbdf21c'u32, 0xcabac28a'u32, 0x53b39330'u32, 0x24b4a3a6'u32,
  0xbad03605'u32, 0xcdd70693'u32, 0x54de5729'u32, 0x23d967bf'u32,
  0xb3667a2e'u32, 0xc4614ab8'u32, 0x5d681b02'u32, 0x2a6f2b94'u32,
  0xb40bbe37'u32, 0xc30c8ea1'u32, 0x5a05df1b'u32, 0x2d02ef8d'u32,
]

proc crc32*(data: openArray[byte]): uint32 =
  ## Compute CRC32 of a byte sequence.
  result = 0xFFFFFFFF'u32
  for b in data:
    result = CRC32_TABLE[int((result xor uint32(b)) and 0xFF)] xor (result shr 8)
  result = result xor 0xFFFFFFFF'u32

proc crc32*(data: openArray[byte], seed: uint32): uint32 =
  ## Incremental CRC32: continue from a previous seed.
  ## To start incremental computation, pass 0xFFFFFFFF as seed.
  ## Final XOR must be applied manually by caller when done.
  result = seed
  for b in data:
    result = CRC32_TABLE[int((result xor uint32(b)) and 0xFF)] xor (result shr 8)

proc crc32*(data: pointer, size: int): uint32 =
  ## Compute CRC32 of a raw memory buffer.
  result = 0xFFFFFFFF'u32
  let bytes = cast[ptr UncheckedArray[byte]](data)
  for i in 0..<size:
    result = CRC32_TABLE[int((result xor uint32(bytes[i])) and 0xFF)] xor (result shr 8)
  result = result xor 0xFFFFFFFF'u32

proc crc32*(s: string): uint32 =
  ## Compute CRC32 of a string.
  result = 0xFFFFFFFF'u32
  for b in s:
    result = CRC32_TABLE[int((result xor uint32(b)) and 0xFF)] xor (result shr 8)
  result = result xor 0xFFFFFFFF'u32

proc crc32ToHex*(crc: uint32): string =
  ## Format CRC32 as zero-padded hex string.
  result = toHex(int64(crc))
  # toHex returns uppercase, 16 chars for int64; trim to 8
  result = result[^8..^1]

when isMainModule:
  # Self-test with known vectors
  assert crc32("") == 0x00000000'u32
  assert crc32("a") == 0xe8b7be43'u32
  assert crc32("abc") == 0x352441c2'u32
  assert crc32("message digest") == 0x20159d7f'u32
  assert crc32("abcdefghijklmnopqrstuvwxyz") == 0x4c2750bd'u32
  assert crc32("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") == 0x1fc2e6d2'u32
  echo "CRC32 self-test passed"
