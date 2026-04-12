## MODIFIED Requirements

### Requirement: Support light/dark mode and user-friendly theming
The system SHALL apply the Apple-like light/dark theme consistently across all pages via a shared layout. The theme toggle SHALL persist via localStorage across page navigations.

#### Scenario: Theme persists across pages
- **WHEN** the user toggles dark mode and navigates to another page
- **THEN** the dark mode preference is retained

#### Scenario: All pages use shared layout styling
- **WHEN** any page loads
- **THEN** the header, navigation, and footer are styled consistently with the active theme
