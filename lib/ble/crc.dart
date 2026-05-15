/// CRC-16/CCITT-XModem.
///
/// Polynomial 0x1021, init 0x0000, no reflection, no final XOR.
/// Matches the AK protocol's `MathUtils.calcCRC_CCITT_XModem`.
int crc16Xmodem(Iterable<int> data) {
  int crc = 0x0000;
  for (final b in data) {
    crc ^= (b & 0xFF) << 8;
    for (int i = 0; i < 8; i++) {
      if ((crc & 0x8000) != 0) {
        crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
      } else {
        crc = (crc << 1) & 0xFFFF;
      }
    }
  }
  return crc;
}
