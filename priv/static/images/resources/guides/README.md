# Resources Guide Images

This directory contains screenshots and images for the step-by-step how-to guides in the Resources section.

## Image Specifications

### Standard Dimensions

**UI Screenshots (16:9 ratio):**
- Width: 1280px
- Height: 720px
- Format: PNG
- Use for: Navigation, buttons, list views

**Form Screenshots (8:5 ratio):**
- Width: 1280px
- Height: 800px
- Format: PNG
- Use for: Forms, modals, detailed views with more vertical content

### Image Guidelines

1. **Capture at standard browser width** (1280px or wider)
2. **Include context** - Show enough of the surrounding UI for orientation
3. **Use annotations** - Add arrows, highlights, or callout boxes to direct attention
4. **Consistent styling** for annotations:
   - Arrows: Red (#EF4444) or Blue (#3B82F6)
   - Highlight boxes: Semi-transparent yellow (#FBBF24 at 30% opacity)
   - Text callouts: White background with dark text

4. **Optimize for web**:
   - Export as PNG-8 or PNG-24
   - Use compression (TinyPNG, ImageOptim)
   - Target file size: < 200KB per image

5. **Accessibility**:
   - Ensure text is readable (minimum 14px)
   - Maintain sufficient contrast
   - Avoid relying solely on color to convey meaning

### Creating Screenshots

#### Recommended Tools:
- **macOS**: Screenshot (Cmd+Shift+4) + Preview for annotations
- **Windows**: Snipping Tool + Paint for annotations
- **Cross-platform**:
  - Snagit (paid, excellent annotation features)
  - Greenshot (free, good basic annotations)
  - Figma (for creating clean annotation overlays)

#### Steps:
1. Navigate to the relevant page in the application
2. Take a full-width screenshot at 1280px+ browser width
3. Crop to appropriate dimensions (1280x720 or 1280x800)
4. Add annotations (arrows, highlights, labels)
5. Export as PNG
6. Optimize/compress the image
7. Replace the `.svg` placeholder with the final PNG

### Current Placeholders

- `board-creation-step-1.png.placeholder.svg` → Replace with: "My Boards" nav link highlighted
- `board-creation-step-2.png.placeholder.svg` → Replace with: "New Board" button + dropdown
- `board-creation-step-3.png.placeholder.svg` → Replace with: Board creation form
- `board-creation-step-4.png.placeholder.svg` → Replace with: New board view with UI pointers

## Naming Convention

Use kebab-case with descriptive names:
```
[guide-id]-step-[number].png
```

Examples:
- `board-creation-step-1.png`
- `understanding-columns-step-2.png`
- `api-authentication-step-3.png`

## File Organization

```
guides/
├── README.md (this file)
├── board-creation-step-1.png
├── board-creation-step-2.png
├── board-creation-step-3.png
├── board-creation-step-4.png
├── understanding-columns-step-1.png
└── ...
```

## Testing

After adding images, verify they display correctly:

1. Start the Phoenix server: `mix phx.server`
2. Navigate to http://localhost:4000/resources/creating-your-first-board
3. Verify all images load and scale appropriately
4. Test on mobile viewport (responsive behavior)
5. Test in dark mode if applicable

## Notes

- SVG placeholders are for development only and should be replaced with actual screenshots
- Keep source files (with layers/annotations) separate from exported PNGs
- Consider creating a "sources" subdirectory for editable files (.psd, .fig, etc.)
