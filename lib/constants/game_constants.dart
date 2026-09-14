import 'dart:ui';

enum Direction { up, down, left, right }

enum CatSkin { red, black, tuxedo }

enum GameLevel { meadow, livingRoom, garden }

const levelName = {
  GameLevel.meadow: 'Wiese',
  GameLevel.livingRoom: 'Wohnzimmer',
  GameLevel.garden: 'Garten',
};

const levelDescription = {
  GameLevel.meadow: 'Entspannt · Rand-Warp · keine Hindernisse',
  GameLevel.livingRoom: 'Schneller · feste Wände · Möbel',
  GameLevel.garden: 'Rasant · Rand-Warp · Beete und Teich',
};

const levelUnlockScore = {
  GameLevel.meadow: 0,
  GameLevel.livingRoom: 100,
  GameLevel.garden: 250,
};

const levelStartSpeed = {
  GameLevel.meadow: 180,
  GameLevel.livingRoom: 165,
  GameLevel.garden: 150,
};

const levelWrapWalls = {
  GameLevel.meadow: true,
  GameLevel.livingRoom: false,
  GameLevel.garden: true,
};

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
