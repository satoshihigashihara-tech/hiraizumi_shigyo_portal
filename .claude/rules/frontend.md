# Frontend Development Rules

## Tailwind CSS

- Use utility classes first, minimize custom CSS
- Mobile-first breakpoints: `sm:`, `md:`, `lg:`, `xl:`
- Use design system tokens defined in `global.css` (colors, fonts)
- Avoid `@apply` except in `global.css` base layer

## GSAP Animation

- Import GSAP in `<script>` tags (client-side only)
- Register plugins: `gsap.registerPlugin(ScrollTrigger)`
- Animate only `transform` and `opacity` for performance
- Use `autoAlpha` instead of `opacity` for visibility handling
- Progressive Enhancement: content must be visible without JS

## Typography

- Headings: Oswald (uppercase, tracking-wider)
- Body: Inter
- Import via `@fontsource/oswald` and `@fontsource/inter`

## Responsive Design

- Mobile-first approach
- Test at: 375px, 390px, 768px, 1024px+
- Hamburger menu on mobile, horizontal nav on desktop
