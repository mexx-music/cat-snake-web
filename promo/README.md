# Cat Snake – Original-Promomaterial

Dieser Ordner enthält ausschließlich reproduzierbare Aufnahmen aus dem echten
Spiel. Der Promo-Einstiegspunkt verwendet dieselben Flutter-Widgets, Painter,
Assets, Level, Effekte und Bedienelemente wie die normale App. Ohne den
separaten Promo-Einstiegspunkt bleibt das normale Spiel unverändert.

## Screenshots neu erzeugen

```sh
bash tool/capture_promo.sh
```

Der Export baut den separaten Promo-Einstiegspunkt und nimmt ihn mit echtem
Headless Chrome auf. Dadurch entsprechen Schrift, Material-Icons, Canvas und
Web-Rendering exakt der echten Web-App. Widgettest-Platzhalterschriften werden
bewusst nicht für das Werbematerial verwendet.

Die PNG-Dateien werden über das Chrome DevTools Protocol erst nach der ersten
vollständig gezeichneten Flutter-Oberfläche aufgenommen:

- 9:16: 1440 × 2560 Pixel
- 16:9: 2560 × 1440 Pixel

## Promo-Modus im Browser

```sh
flutter run -d chrome -t lib/promo/promo_main.dart
```

Szenen können über `?scene=<id>&lang=de` ausgewählt werden. Verfügbare IDs:

- `clean-start`
- `early-gameplay`
- `medium-snake`
- `long-snake`
- `curve-showcase`
- `high-score`
- `mouse-bonus`
- `game-over`
- `demo`

Mit `lang=en` wird dieselbe Szene mit der echten englischen Oberfläche gezeigt.

`?scene=demo&lang=de` startet automatisch eine reproduzierbare Kurvenfolge.
Sie verwendet den normalen Spiel-Ticker, die echte Bewegung und dieselbe
Richtungs-Pufferung wie das reguläre Gameplay. Damit kann später ohne
zusätzliche Demo-Grafik eine identische 9:16-Bildschirmaufnahme erstellt werden.
