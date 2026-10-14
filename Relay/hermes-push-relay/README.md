# push.hermesapp.dev

Vercel proxy in front of the Hermes push relay (Convex prod `acrobatic-goat-299`, eu-west-1). Convex's
Starter plan has no custom domains, so this project only rewrites every path to the Convex site URL.
Deploy: `vercel deploy --prod --yes --scope vburojevic` from this folder.
