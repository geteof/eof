# Diagrams

A flowchart:

```mermaid
flowchart LR
  A[Open file] --> B{Markdown?}
  B -- yes --> C[Preview]
  B -- no --> D[Editor]
```

A sequence diagram:

```mermaid
sequenceDiagram
  participant U as User
  participant E as EOF
  U->>E: Edit text
  E-->>U: Updated preview
```

A diagram with a mistake, which keeps its code and shows Mermaid's message:

```mermaid
flowchart LR
  A --> 
```

Ordinary code stays code:

```swift
print("hello")
```
