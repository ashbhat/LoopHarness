# Yelp Integration

Loop can search for local businesses — restaurants, cafés, services, and more
— through the [Yelp Fusion API](https://docs.developer.yelp.com/docs/fusion-intro).

## Setup

1. Create a free Yelp Fusion app at <https://www.yelp.com/developers> → **Create App**.
2. Copy the **API Key** from your app's dashboard.
3. In Loop, go to **Settings → Keys → Yelp** and paste the key.
   Alternatively, say _"set my Yelp API key"_ and dictate/paste it.

The key is stored in the iOS/macOS Keychain and never leaves your device
except to call the Yelp API.

## What it does

| Tool | Description |
|------|-------------|
| `yelp_search_businesses` | Search Yelp for businesses matching a term and location. Returns name, rating, review count, price tier, categories, address, phone, URL, distance in miles, and lat/lon coordinates. |

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `term` | string | yes | What to search for (e.g. "vegetarian dinner", "plumber") |
| `location` | string | no | Text location (e.g. "San Francisco, CA"). Omit when using lat/lon. |
| `latitude` | number | no | Latitude of the search center |
| `longitude` | number | no | Longitude of the search center |
| `radius_meters` | integer | no | Search radius in meters (max 40 000). Default ~8 000 (~5 mi). |
| `limit` | integer | no | Max results, 1–10 (default 5) |
| `categories` | string | no | Comma-separated Yelp category aliases (e.g. "vegan,vegetarian") |
| `price` | string | no | Comma-separated price tiers (e.g. "1,2" for $ and $$) |
| `open_now` | boolean | no | Only show currently open businesses |
| `sort_by` | string | no | "best_match" (default), "rating", "review_count", or "distance" |

Either `location` **or** `latitude`/`longitude` must be provided. When the
user says "near me", the model calls `get_current_location` first and passes
the coordinates to `yelp_search_businesses`.

## Example prompts

- _"Find vegetarian dinner near me"_
- _"Coffee shops in NOPA, SF"_
- _"Best dog-friendly brunch near me"_
- _"Cheap pizza near Union Square, open now"_
- _"Top-rated sushi within 2 miles"_

## Map integration

When results include coordinates (they almost always do), the model can call
`show_places_on_map` to render them as pins on Loop's inline map.

## Follow-up work

- Category auto-complete / browsing
- Business detail lookup (hours, photos, reviews)
- Favorites / bookmarking
- Deep-link directly to the Yelp app on iOS
