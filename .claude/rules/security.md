# Security Guidelines

## NEVER Do This
- Commit `.env` files
- Hardcode API keys or secrets in source code
- Trust client-side validation only

## ALWAYS Do This
- Store sensitive values in environment variables
- Validate form input both client-side and server-side (when applicable)
- Use `rel="noopener noreferrer"` on external links with `target="_blank"`
- Use honeypot fields for spam prevention on forms
