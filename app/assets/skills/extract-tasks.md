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
          priority:
            type: string
            enum: ["high", "medium", "low"]
          due_date:
            type: string
        required: ["title", "priority"]
---

# Instructions
1. Read the `raw_text` provided in the inputs carefully.
2. Identify all concrete, actionable tasks or commit items.
3. For each task, extract a concise `title`, assign a `priority` based on context, and extract a `due_date` if explicitly mentioned.
4. Output the result strictly matching the declared `output_schema`.
