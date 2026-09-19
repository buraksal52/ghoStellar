package envx

import "testing"

func TestGet(t *testing.T) {
	t.Setenv("ENVX_TEST_GET", "value")
	if got := Get("ENVX_TEST_GET", "fallback"); got != "value" {
		t.Errorf("got %q, want value", got)
	}
	if got := Get("ENVX_TEST_UNSET", "fallback"); got != "fallback" {
		t.Errorf("got %q, want fallback", got)
	}
}

func TestGetInt(t *testing.T) {
	t.Setenv("ENVX_TEST_INT", "42")
	if got := GetInt("ENVX_TEST_INT", 7); got != 42 {
		t.Errorf("got %d, want 42", got)
	}
	if got := GetInt("ENVX_TEST_INT_UNSET", 7); got != 7 {
		t.Errorf("got %d, want 7 (unset falls back)", got)
	}
	t.Setenv("ENVX_TEST_INT_BAD", "not-a-number")
	if got := GetInt("ENVX_TEST_INT_BAD", 7); got != 7 {
		t.Errorf("got %d, want 7 (unparseable falls back)", got)
	}
}

func TestMustGet_Panics(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("expected MustGet to panic for an unset key")
		}
	}()
	MustGet("ENVX_TEST_MUST_GET_UNSET")
}

func TestMustGet_ReturnsValue(t *testing.T) {
	t.Setenv("ENVX_TEST_MUST_GET", "value")
	if got := MustGet("ENVX_TEST_MUST_GET"); got != "value" {
		t.Errorf("got %q, want value", got)
	}
}
