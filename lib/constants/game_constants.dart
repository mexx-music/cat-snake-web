import 'dart:ui';

enum Direction { up, down, left, right }

enum CatSkin { red, black, tuxedo }

const skinAsset = {
  CatSkin.red: 'assets/cats/red.png',
  CatSkin.black: 'assets/cats/black.png',
  CatSkin.tuxedo: 'assets/cats/tux.png',
};

const headAsset = {
  CatSkin.red: 'assets/heads/classic.png',
  CatSkin.black: 'assets/heads/round.png',
  CatSkin.tuxedo: 'assets/heads/pixel.png',
};

const skinBodyColors = {
  CatSkin.red: (Color(0xFF8E2A2A), Color(0xFFFF6A6A)), // dunkel -> hell
  CatSkin.black: (Color(0xFF1B1B1B), Color(0xFF6E6E6E)),
  CatSkin.tuxedo: (Color(0xFF2C5364), Color(0xFF9EE7FF)), // leicht bläulich
};

const skinName = {
  CatSkin.black: 'Blacky',
  CatSkin.red: 'Red',
  CatSkin.tuxedo: 'Felix',
};