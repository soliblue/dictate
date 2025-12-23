# CLAUDE.md

## Open Challenges

### Real-Time Transcription vs Accuracy

- Current approach requires waiting several seconds after speaking before transcription completes
- Unable to achieve real-time streaming transcription while maintaining accuracy
- This wait time is a significant UX issue - feels like wasted time

### Cursor Lock During Transcription

- App pastes text where the cursor is focused when transcription finishes
- User cannot move cursor or switch windows while waiting for paste
- Forced to stay idle until transcription completes, blocking other work

## Structure

```
.venv/                    # virtual environment
requirements.txt          # dependencies
dictate.py                # main app
```

## Run

```bash
source .venv/bin/activate && python dictate.py
```

## Rules

### Multi-Agent Environment

- **Multiple agents work on this codebase simultaneously**
- If you encounter a build error or test failure in a file you haven't touched, **do not fix it** - confirm with the user first
- Avoid getting stuck in loops trying to fix issues caused by other agents' in-progress work
- When in doubt about an unexpected error, ask before attempting repairs

### No Background Tasks

- **Never run commands in the background** - always run commands in the foreground
- **Wait for completion** - let each command finish before moving on

### No Wildcard Imports

- **Never use `from x import *`** - always import specific names explicitly

❌ Bad:
```python
from typing import *
```

✅ Good:
```python
import typing
```

### No Comments

- **Never add comments to code** - no exceptions
- **Never add docstrings** - no exceptions
- Code should be self-explanatory through clear naming and structure

### No Single-Use Variables

- If a variable is only read once, return or use the expression directly

❌ Bad:
```python
def get_data():
    result = calculate_something()
    return result
```

✅ Good:
```python
def get_data():
    return calculate_something()
```

### Happy Path

- **Focus on the happy path** - write if conditions for when you do actual work
- **Less code is better**

### No Try-Except

- **Never add try-except blocks** unless the user explicitly requests error handling
- **Let exceptions propagate naturally**
- **Fail fast and loud**

### No Single-Use Functions

- If a function is only used once and is not longer than 10 lines, integrate it inline

### Use Default Parameters

- Use default parameter values instead of checking if a parameter is None

### Prefer Ternary

- **Use ternary operator for simple conditional assignments**

### No Shebang

- **Never add shebang lines** - don't include `#!/usr/bin/env python3`

### Prefer Comprehensions

- **Use list/dict comprehensions instead of loops** when building collections

### Single Line Print

- **Combine related prints into a single line** when possible

### Simplicity First

- **Less is more** - always prefer the simplest solution
- **Code should be beautiful** - treat it like an art piece
