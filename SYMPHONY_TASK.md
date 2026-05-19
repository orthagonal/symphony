# TASK-19: the delete task didn't work

**Status:** assigned
**Dashboard:** http://127.0.0.1:4321/tasks/19
**Workspace mode:** linked
**Project folder:** c:/GitHub/symphony

## Git

- **Summary:** main @ bbef623 (dirty) · https://github.com/openai/symphony.git
- **Branch:** main
- **Commit:** `bbef62364db25970cf0e732fc61011ab753d2604`
- **Origin:** https://github.com/openai/symphony.git
- **Working tree:** 59 changed file(s) (uncommitted changes)



## Description

this was supposed to add a 'delete' button in another task but I think it did it in a copied folder.  Can you bring that back into the main branch if so?

## Plan (from Ollama)

_Run “Plan for Cursor” on the dashboard, then click Prepare workspace again._

## Mark complete

Symphony marks this task **done** automatically when headless `cursor-agent` exits successfully.

Optional manual API (from PowerShell or bash):

```bash
curl -X POST "http://127.0.0.1:4321/api/v1/tasks/19/status" -H "Content-Type: application/json" -d "{\"status\":\"done\"}"
```

