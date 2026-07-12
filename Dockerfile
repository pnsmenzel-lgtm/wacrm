# syntax=docker/dockerfile:1

# ============================================================
# wacrm — production image for EasyPanel (Next.js 16 standalone)
#
# Multi-stage build:
#   deps    → install node_modules (cached unless lockfile changes)
#   builder → `next build` producing the standalone bundle
#   runner  → minimal runtime, non-root, ~150 MB
#
# EasyPanel: set the build type to "Dockerfile", exposed port 3000,
# and add the env vars from .env.local.example under the App → Environment
# tab. NEXT_PUBLIC_* vars are baked at BUILD time, so pass them as build
# args too (see the ARG/ENV block in the builder stage).
# ============================================================

# ---- Base -------------------------------------------------------------
FROM node:22-alpine AS base
# libc6-compat: some native deps (and Next's SWC binary) expect glibc symbols.
RUN apk add --no-cache libc6-compat
WORKDIR /app

# ---- Dependencies -----------------------------------------------------
FROM base AS deps
# Copy only the manifests first so this layer is cached across code changes.
COPY package.json package-lock.json ./
RUN npm ci

# ---- Builder ----------------------------------------------------------
FROM base AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .

# NEXT_PUBLIC_* values are inlined into the client bundle at build time,
# so they must be present here — not just at runtime. EasyPanel forwards
# these as build args when you declare them; runtime-only secrets
# (SUPABASE_SERVICE_ROLE_KEY, ENCRYPTION_KEY, META_APP_SECRET, …) are read
# at runtime and must NOT be baked in.
ARG NEXT_PUBLIC_SUPABASE_URL
ARG NEXT_PUBLIC_SUPABASE_ANON_KEY
ARG NEXT_PUBLIC_SITE_URL
ARG NEXT_PUBLIC_APP_LOCALE
ENV NEXT_PUBLIC_SUPABASE_URL=$NEXT_PUBLIC_SUPABASE_URL \
    NEXT_PUBLIC_SUPABASE_ANON_KEY=$NEXT_PUBLIC_SUPABASE_ANON_KEY \
    NEXT_PUBLIC_SITE_URL=$NEXT_PUBLIC_SITE_URL \
    NEXT_PUBLIC_APP_LOCALE=$NEXT_PUBLIC_APP_LOCALE \
    NEXT_TELEMETRY_DISABLED=1

RUN npm run build

# ---- Runner -----------------------------------------------------------
FROM base AS runner
WORKDIR /app

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0

# Run as an unprivileged user.
RUN addgroup --system --gid 1001 nodejs \
 && adduser --system --uid 1001 nextjs

# The standalone output already contains a minimal server.js plus only the
# node_modules it actually needs. `public` and `.next/static` are NOT copied
# into standalone automatically, so we add them explicitly.
COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs

EXPOSE 3000

CMD ["node", "server.js"]
