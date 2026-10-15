s = "Hello"
print(s[1], s[-1], s[1:4], s[:2], s[2:], len(s))
print(s.lower(), s.upper(), s.find("ll"), s.find("z"))
print(s.replace("l", "L"), s.count("l"))
print(s.startswith("He"), s.endswith("lo"), "x".startswith("He"))
print("  ab  ".strip(), "ab".lstrip("a"), "ab".rstrip("b"))
print("a,b,c".split(","), "a  b".split(), "ab".join(["1", "2", "3"]))
print("abc".partition("b"), "abc".rpartition("b"))
print("a" + "b", "ab" * 3, "a" < "b", "a" in "cat")
print(repr("a'b"), repr('a"b'), repr("a\nb"))
try:
    print("abc"[5])
except Exception as e:
    print(type(e).__name__, e)
