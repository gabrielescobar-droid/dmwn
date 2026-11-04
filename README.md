[DRAFT — needs human review]

# DM What's Next? (Vercel)

## Files (all at repo root)
- index.html          the page
- vercel.json         static site settings
- api/chat.js         AI helper for "Ask a Question" (Vercel serverless function)

## Turn on the AI helper
1. Get an Anthropic API key (console.anthropic.com), ideally a key made only for this page.
2. Vercel > project dmwn > Settings > Environment Variables:
   ANTHROPIC_API_KEY = (paste key)   Environments: Production (and Preview if you test there)
3. Redeploy. Never put the key in any file in this repo.
4. In the Anthropic console, set a monthly spend limit for that key.
Without the key, "Ask a Question" still works with built-in quick answers.

## Before deploying
- Set SUPABASE_URL and SUPABASE_ANON_KEY in index.html when analytics are ready.
- Run dm-whats-next-supabase.sql in Supabase, then set the admin passcode in the SQL editor.

## Member links
https://dmwn.vercel.app/?m={contact_id}&src=email
HubSpot token: ?m={{ contact.hs_object_id }}&src=email
