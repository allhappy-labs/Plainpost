# Plainpost app icon source

The production icon is the rebuilt blue Liquid Glass envelope artwork in
`AppIcon-Master-1024.png`. Its canvas is transparent outside the envelope: the
old blue rounded-square backdrop is not part of the production icon.

Layer order, back to front:

1. `01-Background.png` - blue and cyan enclosure/background
2. `02-Interior-Seal.png` - dark envelope interior and cyan seal
3. `03-Front-Pocket.png` - translucent lower pocket and crossed folds
4. `04-Glass-Flap.png` - upper glass flap and specular rim

`AppIcon-Master-1024.png` is the approved flattened master and the sole source
for the `.iconset` and `.icns` resource used by the macOS app bundle. The
envelope is optically centered with an 88px left/right margin and a 64px
top/bottom margin on its 1024px canvas. Flattening against white produces a
visible halo around the icon in Finder and the Dock and is not allowed.

The numbered layer files preserve the earlier Composer construction reference.
Do not reassemble them into the current app icon, because they depend on the
removed blue enclosure. To create or update a native Liquid Glass document in
Icon Composer, start from the approved flattened master:

1. Create a 1024 x 1024 macOS icon document.
2. Import `AppIcon-Master-1024.png` as the icon artwork.
3. Preview Default, Dark, and Mono appearances to confirm the transparent
   exterior does not create a second border.
4. Save the document as `AppIcon.icon` and add it to the Xcode application target.

The checked-in `.icns` remains the compatibility fallback and lets command-line
and older build environments render the same approved artwork.
