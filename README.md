# Tindu Backery cake ordering

WhatsApp-first storefront for a single home bakery. Customers browse a cake menu, make a multi-item request, and receive a private tracking link. The seller confirms delivery details, verifies UPI payment manually, and posts preparation updates.

## Run locally

1. Install Node.js 20.9 or later.
2. Copy `.env.example` to `.env.local` and add your Supabase project URL and anon key.
3. Run `npm install` and `npm run dev`.
4. Follow **Supabase setup** below before placing real customer orders.

Without Supabase variables, the home page displays a sample catalog for preview. It deliberately cannot create orders; production orders must go through the database RPCs.

## Supabase setup

1. Create a Supabase project. In **Project Settings → API**, copy the project URL and anon/public key into `.env.local`. Never put the `service_role` key in this application.
2. In **SQL Editor**, run `supabase/schema.sql`.
3. In **Authentication → Users**, create the seller account with email and password. Disable public sign-ups in Auth settings.
4. In the SQL editor, associate the single bakery with the seller account (replace the email):

   ```sql
   update public.store_settings
   set owner_id = (select id from auth.users where email = 'YOUR_SELLER_EMAIL')
   where singleton = true;
   ```

5. Start the site and sign in at `/admin`. Add your real cake listings, photo, ingredients, prices, UPI ID, contact number, and delivery coverage.
6. Set Supabase Auth's site URL and redirect URL to the deployed site. Deploy on Vercel by importing this project and adding the two `NEXT_PUBLIC_SUPABASE_*` environment variables.

## Order behavior

- Customer cart totals show cake prices only. Delivery is confirmed by the baker after the request; the final total is cake subtotal plus the seller-entered delivery fee.
- The database rechecks current cake availability, variants, prices, flavours, and advance notice at request time. A tracking URL contains a 256-bit random bearer token; keep it private and share it only with the customer.
- Customers can provide a preferred date/time or let the baker suggest a time. The seller must enter the confirmed delivery time and fee before accepting.
- The tracking page provides a UPI intent after acceptance. The seller verifies payment in their UPI app and marks it received before the database allows baking updates.
- Dashboard WhatsApp buttons open a prefilled message for review. Messages are not sent automatically. UPI is not automatically verified.
- Product photos can be uploaded to the public `cake-photos` bucket or supplied by URL. Do not upload private customer data as product imagery.

## Deployment notes

Use HTTPS in production. Supabase row-level security limits catalog edits and order access to the seller account; public customers can only submit an order through the validation RPC and read the order that matches their private tracking token. The current implementation is for one bakery account/store.
