---
name: extract-tasks
description: Extracts actionable tasks from raw text and formats them as structured JSON.
inputs:
  raw_text:
    type: string
    description: The unstructured text containing tasks or meeting notes.
    required: true
output_schema:
  type: object
  properties:
    tasks:
      type: array
      items:
        type: object
        properties:
          title:
            type: string
            description: Short imperative phrase, prefixed with the owner if named.
          priority:
            type: string
            enum: ["high", "medium", "low"]
          due_date:
            type: string
            description: Deadline exactly as written. Omit when there is none.
        required: ["title", "priority"]
---

# Instructions
1. Read the `raw_text` provided in the inputs carefully.
2. Extract only concrete actions someone has to do. Meeting names, dates of the meeting, attendees, greetings, thanks and background facts are not tasks. If the text contains no actions, output {"tasks": []}. Never invent a task, and never use "None" as a title.
3. Make one task per action. Write `title` as a short imperative phrase; if a person is responsible, start with their name, e.g. "Ana: send revised budget to finance".
4. Choose `priority`:
   - `high`: called urgent, important or ASAP, or due within the next few days.
   - `medium`: has a later deadline, or is clearly expected but has no deadline.
   - `low`: optional, or described as "eventually", "someday" or "if time allows".
5. Include `due_date` only when the text states a deadline, copied as written (e.g. "Friday", "Nov 15"). When there is no deadline, leave the `due_date` key out completely. Never write "None", "N/A", "TBD" or an empty string.
6. Output the result strictly matching the declared `output_schema`.

# Examples
Text: "Standup, Monday. Raj must fix the login bug today, it's blocking QA. Mia will draft the Q3 report by June 30. Maybe someday we clean up old branches."
Output: {"tasks":[{"title":"Raj: fix the login bug","priority":"high","due_date":"today"},{"title":"Mia: draft the Q3 report","priority":"medium","due_date":"June 30"},{"title":"Clean up old branches","priority":"low"}]}

Text: "Thanks for coming yesterday, the party was lovely."
Output: {"tasks":[]}
