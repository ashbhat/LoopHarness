# Message Box, Mic Button

## Context:
I'm trying to add a mic record button with a wide touch area to the message box.

This button should be virtically aligned with the same height to the send and keyboard buttons but be wider.
It should have a system blue border with width of 2px and have the mic.fill icon at the center

When tapped, the entire MessageBox should turn into a recording UI that looks like this

 ⏹️ _ _ _ _ _  | | | | | | | | | | | | | ⬆️

 the lines should each second and eventually fill up 


 ⏹️ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ | ⬆️ (start)
 ⏹️ _ _ _ _ _ _ | | | | | | | | | | | | | ⬆️ (during)

## Functionality:
When the user taps the mic button, the system should ask for mic permissions if it doesn't yet have it. 
Once the user grants the permissions, it should flip to the recording UI and begin recording audio.

⏹️ _ _ _ _ _ _ | | | | | | | | | | | | | ⬆️

When the user taps the up arrow to send the entire MessageBox should turn into a purple to blue gradient that's animating through those gradients left to right with the word transcribing... in the middle

[                 transcribing              ]

Upon completing transcription using Apple's native transcription framework, the result should be sent as message the user typed and leave the user with an empty message box as the AI on the otherside types it's response. This completes the golden path of this feature.

Alternatively the user could start recording
⏹️ _ _ _ _ _ _ | | | | | | | | | | | | | ⬆️

And then hit stop.

This would return the user to the empty message box read to let the user type.