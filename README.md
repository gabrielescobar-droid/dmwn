[DRAFT — needs human review]

# DM What's Next? (static site for Vercel)

## Before deploying
1. In index.html, set SUPABASE_URL, SUPABASE_ANON_KEY, STEP0_URL, PAGE_URL (your final URL).
2. Run dm-whats-next-supabase.sql in Supabase, then set the admin passcode in the SQL editor.
3. Swap stand-in assets (search "REPLACE ASSET").

## Deploy option A: Vercel CLI (fastest)
    npm i -g vercel
    cd dm-whats-next-vercel
    vercel            # preview URL, check it
    vercel --prod     # production

## Deploy option B: GitHub
1. Push this folder to a GitHub repo.
2. vercel.com/new, import the repo, framework preset "Other", no build command.
3. Every push redeploys.

## Member links
https://YOUR-DOMAIN/?m={contact_id}&src=email
HubSpot token: ?m={{ contact.hs_object_id }}&src=email
