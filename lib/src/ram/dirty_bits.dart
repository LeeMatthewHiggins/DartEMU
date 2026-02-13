import 'dart:typed_data';

class DirtyBits {
  DirtyBits({required int ramSize}) {
    final pageCount = (ramSize + _pageSize - 1) >> _pageSizeLog2;
    final wordCount = (pageCount + _bitsPerWord - 1) >> _bitsPerWordLog2;
    _table0 = Uint32List(wordCount);
    _table1 = Uint32List(wordCount);
  }

  late final Uint32List _table0;
  late final Uint32List _table1;
  var _currentTable = 0;

  Uint32List get _active => _currentTable == 0 ? _table0 : _table1;

  void set(int pageIndex) {
    final word = pageIndex >> _bitsPerWordLog2;
    final bit = pageIndex & _bitMask;
    _table0[word] |= 1 << bit;
    _table1[word] |= 1 << bit;
  }

  Uint32List swapAndClear() {
    final old = _active;
    _currentTable ^= 1;
    final cleared = _active;
    for (var i = 0; i < cleared.length; i++) {
      cleared[i] = 0;
    }
    return old;
  }

  static const _pageSizeLog2 = 12;
  static const _pageSize = 1 << _pageSizeLog2;
  static const _bitsPerWord = 32;
  static const _bitsPerWordLog2 = 5;
  static const _bitMask = _bitsPerWord - 1;
}
