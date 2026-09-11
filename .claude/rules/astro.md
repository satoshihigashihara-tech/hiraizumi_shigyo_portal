# Astro Development Rules

## Project Structure

- Pages: `src/pages/` (file-based routing)
- Layouts: `src/layouts/`
- Components: `src/components/` (PascalCase, e.g., `HeroVideo.astro`)
- Data: `src/data/` (mock data / static data)
- Lib: `src/lib/` (utilities, API clients, types)
- Styles: `src/styles/global.css`
- Assets: `src/assets/` (images, videos processed by Astro)

## Naming Conventions

- Components: PascalCase (`MemberCard.astro`)
- Pages: kebab-case (`index.astro`, `[slug].astro`)
- TypeScript files: camelCase (`wordpress.ts`, `types.ts`)

## Component Guidelines

- Use `.astro` components by default (zero JS)
- Only use `client:*` directives when interactivity is required
- Prefer `client:visible` over `client:load` for non-critical interactive elements
- Use Astro `<Image>` component for all images (automatic optimization)
- Keep component props typed with TypeScript interfaces

## Performance

- Use `<Image>` component for automatic WebP conversion and sizing
- Lazy load below-the-fold images
- Keep JavaScript minimal — use `<script>` tags for client-side code
- Prefer View Transitions API for page transitions

## Build & Dev

```bash
npm run dev      # Development server
npm run build    # Production build
npm run preview  # Preview production build
```
