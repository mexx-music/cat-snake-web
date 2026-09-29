# Responsive Board – Vergleichsaufnahmen

Diese Bilder werden aus der echten produktiven Flutter-Web-App aufgenommen.
Es werden keine Promo-Szenen oder Ersatzgrafiken verwendet.

## Vergleich

- `before_small_iphone_390x844.png`: bisheriges 22×16-Board auf kleinem
  Portrait-Handy
- `after_small_iphone_390x844.png`: neues 14×22-Board auf demselben Viewport

## Weitere geprüfte Viewports

- `after_large_phone_430x932.png`
- `after_android_412x915.png`
- `after_phone_landscape_844x390.png`
- `after_tablet_portrait_820x1180.png`
- `after_desktop_1440x900.png`

Neu erzeugen:

```sh
CAPTURE_SET=after bash tool/capture_responsive.sh
```

Die Nachher-Aufnahmen werden mit doppelter Pixeldichte exportiert. Der
Vorher-Vergleich bleibt als Referenz auf die Version vor der responsiven
Board-Umstellung erhalten.
