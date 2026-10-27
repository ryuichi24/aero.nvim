# Go Coding Conventions

## Declaration Spacing

Separate each top-level declaration (`type`, `func`, `const`, or `var`) from the
next declaration with a blank line, including consecutive struct definitions and
single-line declarations. Do not rely solely on formatter or linter checks to
enforce this convention. Preserve attached documentation comments and compiler
directives with their declarations. Do not manually edit generated code.

```go
type Project struct {
	ID string `json:"id"`
}

type Monorepo struct {
	Projects []Project `json:"projects"`
}

type Config struct {
	Monorepo *Monorepo `json:"monorepo,omitempty"`
}
```
