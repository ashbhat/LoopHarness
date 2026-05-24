# Action Button Spec

I want to enable an action button that triggers voice transcription.
I'm thinking of activating this with a url scheme

intel://mic

When I use the url scheme above, it should toggle voice transcription in the current chat. If it's a cold start, it should wait to load the chat based on existing logic and then trigger voice transcription in the MessageBox. If voice transcription is currently running, it should send the current recording.

# Functionality
To accomplish this, you should register the url scheme intel:// and on app open, you should handle the /mic command and trigger the logic above.

Once we've implemented this in the code, i'll trigger a action button at the iOS system level that opens the url scheme intel://mic