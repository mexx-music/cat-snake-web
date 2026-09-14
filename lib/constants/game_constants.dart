import 'dart:ui';

enum Direction { up, down, left, right }

enum CatSkin { red, black, tuxedo }

const skinBodyColors = {
  CatSkin.red: (Color(0xFF7A3420), Color(0xFFF18A43)),
  CatSkin.black: (Color(0xFF15181D), Color(0xFF515A64)),
  CatSkin.tuxedo: (Color(0xFF171A1F), Color(0xFF444B54)),
};

const skinName = {
  CatSkin.black: 'Blacky',
  CatSkin.red: 'Red',
  CatSkin.tuxedo: 'Felix',
};
