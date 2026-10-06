# Proxmox Link: the shared core. Dot-sourced by ProxmoxLink.ps1 (the poller and tray icon), ProxmoxLink-Setup.ps1 (the
# setup window), ProxmoxLink-Install.ps1 and the tests. Runs on Windows PowerShell 5.1 and PowerShell 7.
#
# What Proxmox Link does: it reads Proxmox VE, Proxmox Backup Server and Proxmox Datacenter Manager with a read-only API
# token and writes what it reads to %APPDATA%\ProxmoxControl\state.json, the file the Proxmox Dashboard widget for the
# CORSAIR XENEON EDGE watches. The file is the one the Stream Deck plugin Proxmox & PBS Control writes, field for field
# (that plugin's docs/STATE-FILE.md), with writer "companion". While Proxmox Link runs it also writes companion.json
# (a heartbeat) beside it, and the plugin, if it is installed too, stops writing state.json.
#
# Nothing else is written outside %LOCALAPPDATA%\ProxmoxLink (settings and a small log). Token secrets are kept in
# settings encrypted with Windows DPAPI for the current user, and never go into the state file or the log.
#
# Certificates: Proxmox servers use self-signed certificates. Proxmox Link never turns certificate checks off for the
# process. Each request carries its own validation callback, which accepts only the certificate whose SHA-256
# fingerprint the user trusted in setup for that connection (trust on first use), or, if the user ticked it for that
# connection, a certificate Windows itself trusts. A refused certificate ends the TLS handshake before any request, and
# so before the token, is sent.

$script:PxVersion = '1.0.0'
$script:PxApp = 'Proxmox & PBS Control'   # the state file's "app": the format's name, shared with the plugin
$script:PxSchema = 1
$script:PxKeys = @('A', 'B', 'C')
$script:PxKinds = @('pve', 'pbs', 'pdm')
$script:PxDefaultPort = @{ pve = 8006; pbs = 8007; pdm = 8443 }
$script:PxKindName = @{ pve = 'Proxmox VE'; pbs = 'Proxmox Backup Server'; pdm = 'Proxmox Datacenter Manager' }
# Lists are capped as the plugin caps them, so a big estate cannot make the file huge.
$script:PxCaps = @{ nodes = 64; guests = 600; storages = 120; tasks = 15; datastores = 32; groups = 400; remotes = 32 }
# The light extra Proxmox VE calls the plugin makes for the widget: quorum and tasks every 30 s, node load every 60 s.
$script:PxExtraMs = @{ cluster = 30000; tasks = 30000; loads = 60000 }
$script:PxRefusedMs = 600000
$script:PxMaxLoadNodes = 16

# ---------------------------------------------------------------------------------------------------------------------
# The C# helper: JSON exactly as JavaScript reads and writes it, JavaScript's number and string rules, HTTPS with a
# per-request certificate check, and a small log. C# 5 only, so Windows PowerShell 5.1's compiler takes it.
# ---------------------------------------------------------------------------------------------------------------------
$script:PxCSharp = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.RegularExpressions;

namespace ProxmoxLink
{
    /// <summary>JSON.parse and JSON.stringify, as Node does them (the plugin is Node), so the files match.</summary>
    public static class Json
    {
        public static object Parse(string text)
        {
            if (text == null) throw new FormatException("No JSON");
            Parser p = new Parser(text);
            p.Ws();
            object v = p.Value(0);
            p.Ws();
            if (p.Pos != text.Length) throw new FormatException("Unexpected characters after JSON");
            return v;
        }

        sealed class Parser
        {
            readonly string s;
            public int Pos;
            public Parser(string s) { this.s = s; }
            public void Ws() { while (Pos < s.Length && (s[Pos] == ' ' || s[Pos] == '\t' || s[Pos] == '\n' || s[Pos] == '\r')) Pos++; }
            Exception Err(string m) { return new FormatException(m + " at " + Pos); }
            char Peek() { if (Pos >= s.Length) throw Err("Unexpected end of JSON"); return s[Pos]; }
            void Expect(char c) { if (Peek() != c) throw Err("Expected '" + c + "'"); Pos++; }
            public object Value(int depth)
            {
                if (depth > 512) throw Err("JSON nested too deeply");
                char c = Peek();
                if (c == '{') return Obj(depth);
                if (c == '[') return Arr(depth);
                if (c == '"') return Str();
                if (c == 't') { Lit("true"); return true; }
                if (c == 'f') { Lit("false"); return false; }
                if (c == 'n') { Lit("null"); return null; }
                return Num();
            }
            void Lit(string w) { if (string.CompareOrdinal(s, Pos, w, 0, w.Length) != 0) throw Err("Bad literal"); Pos += w.Length; }
            Hashtable Obj(int depth)
            {
                Pos++;
                Hashtable h = new Hashtable(StringComparer.Ordinal);
                Ws();
                if (Peek() == '}') { Pos++; return h; }
                for (;;)
                {
                    Ws();
                    if (Peek() != '"') throw Err("Expected a key");
                    string k = Str();
                    Ws(); Expect(':'); Ws();
                    h[k] = Value(depth + 1);
                    Ws();
                    if (Peek() == ',') { Pos++; continue; }
                    Expect('}');
                    return h;
                }
            }
            object[] Arr(int depth)
            {
                Pos++;
                List<object> list = new List<object>();
                Ws();
                if (Peek() == ']') { Pos++; return list.ToArray(); }
                for (;;)
                {
                    Ws();
                    list.Add(Value(depth + 1));
                    Ws();
                    if (Peek() == ',') { Pos++; continue; }
                    Expect(']');
                    return list.ToArray();
                }
            }
            string Str()
            {
                Pos++;
                StringBuilder sb = new StringBuilder();
                for (;;)
                {
                    char c = Peek();
                    Pos++;
                    if (c == '"') return sb.ToString();
                    if (c < ' ') throw Err("Control character in string");
                    if (c != '\\') { sb.Append(c); continue; }
                    char e = Peek();
                    Pos++;
                    switch (e)
                    {
                        case '"': sb.Append('"'); break;
                        case '\\': sb.Append('\\'); break;
                        case '/': sb.Append('/'); break;
                        case 'b': sb.Append('\b'); break;
                        case 'f': sb.Append('\f'); break;
                        case 'n': sb.Append('\n'); break;
                        case 'r': sb.Append('\r'); break;
                        case 't': sb.Append('\t'); break;
                        case 'u':
                            if (Pos + 4 > s.Length) throw Err("Bad \\u escape");
                            sb.Append((char)int.Parse(s.Substring(Pos, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture));
                            Pos += 4;
                            break;
                        default: throw Err("Bad escape");
                    }
                }
            }
            object Num()
            {
                int start = Pos;
                if (Pos < s.Length && s[Pos] == '-') Pos++;
                int digits = Pos;
                while (Pos < s.Length && s[Pos] >= '0' && s[Pos] <= '9') Pos++;
                if (Pos == digits) throw Err("Bad number");
                if (Pos < s.Length && s[Pos] == '.') { Pos++; int f = Pos; while (Pos < s.Length && s[Pos] >= '0' && s[Pos] <= '9') Pos++; if (Pos == f) throw Err("Bad number"); }
                if (Pos < s.Length && (s[Pos] == 'e' || s[Pos] == 'E'))
                {
                    Pos++;
                    if (Pos < s.Length && (s[Pos] == '+' || s[Pos] == '-')) Pos++;
                    int x = Pos; while (Pos < s.Length && s[Pos] >= '0' && s[Pos] <= '9') Pos++;
                    if (Pos == x) throw Err("Bad number");
                }
                // Every JSON number is a double, as in JavaScript.
                return double.Parse(s.Substring(start, Pos - start), NumberStyles.Float, CultureInfo.InvariantCulture);
            }
        }

        public static string Stringify(object value)
        {
            StringBuilder sb = new StringBuilder();
            Write(sb, value, 0);
            return sb.ToString();
        }

        /// <summary>PowerShell may hand values over wrapped in a PSObject; the helper does not reference PowerShell.</summary>
        public static object Unwrap(object v)
        {
            for (int i = 0; i < 8 && v != null; i++)
            {
                Type t = v.GetType();
                if (t.FullName == "System.Management.Automation.PSObject")
                {
                    object b = t.GetProperty("BaseObject").GetValue(v, null);
                    if (ReferenceEquals(b, v)) return v;
                    v = b;
                    continue;
                }
                // PowerShell's "nothing" (an empty $( ) or a branch that wrote nothing) arrives as an empty custom object.
                if (t.FullName == "System.Management.Automation.Internal.AutomationNull" || t.FullName == "System.Management.Automation.PSCustomObject") return null;
                return v;
            }
            return v;
        }

        static void Write(StringBuilder sb, object value, int depth)
        {
            if (depth > 64) throw new InvalidOperationException("Too deep to write");
            object v = Unwrap(value);
            if (v == null) { sb.Append("null"); return; }
            if (v is string) { Quote(sb, (string)v); return; }
            if (v is char) { Quote(sb, v.ToString()); return; }
            if (v is bool) { sb.Append((bool)v ? "true" : "false"); return; }
            if (v is double || v is float || v is decimal) { sb.Append(Js.NumberText(Convert.ToDouble(v, CultureInfo.InvariantCulture))); return; }
            if (v is int || v is long || v is short || v is byte || v is sbyte || v is uint || v is ulong || v is ushort)
            {
                sb.Append(Convert.ToString(v, CultureInfo.InvariantCulture));
                return;
            }
            IDictionary d = v as IDictionary;
            if (d != null)
            {
                sb.Append('{');
                bool first = true;
                foreach (DictionaryEntry e in d)
                {
                    if (!first) sb.Append(',');
                    first = false;
                    Quote(sb, Convert.ToString(e.Key, CultureInfo.InvariantCulture));
                    sb.Append(':');
                    Write(sb, e.Value, depth + 1);
                }
                sb.Append('}');
                return;
            }
            IEnumerable list = v as IEnumerable;
            if (list != null)
            {
                sb.Append('[');
                bool first = true;
                foreach (object o in list)
                {
                    if (!first) sb.Append(',');
                    first = false;
                    Write(sb, o, depth + 1);
                }
                sb.Append(']');
                return;
            }
            Quote(sb, Convert.ToString(v, CultureInfo.InvariantCulture));
        }

        /// <summary>JSON.stringify's string quoting, lone surrogates escaped as Node does.</summary>
        public static void Quote(StringBuilder sb, string s)
        {
            sb.Append('"');
            for (int i = 0; i < s.Length; i++)
            {
                char c = s[i];
                switch (c)
                {
                    case '"': sb.Append("\\\""); continue;
                    case '\\': sb.Append("\\\\"); continue;
                    case '\b': sb.Append("\\b"); continue;
                    case '\f': sb.Append("\\f"); continue;
                    case '\n': sb.Append("\\n"); continue;
                    case '\r': sb.Append("\\r"); continue;
                    case '\t': sb.Append("\\t"); continue;
                }
                if (c < ' ') { sb.Append("\\u").Append(((int)c).ToString("x4")); continue; }
                if (char.IsHighSurrogate(c))
                {
                    if (i + 1 < s.Length && char.IsLowSurrogate(s[i + 1])) { sb.Append(c).Append(s[i + 1]); i++; continue; }
                    sb.Append("\\u").Append(((int)c).ToString("x4"));
                    continue;
                }
                if (char.IsLowSurrogate(c)) { sb.Append("\\u").Append(((int)c).ToString("x4")); continue; }
                sb.Append(c);
            }
            sb.Append('"');
        }
    }

    /// <summary>JavaScript's rules for the few things the plugin's feed.js does with values, so the output matches.</summary>
    public static class Js
    {
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static readonly CompareInfo Collation = new CultureInfo("en-US").CompareInfo;

        public static long Now() { return (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds; }

        /// <summary>A dictionary's value, or null for a missing key or a value that is not a dictionary.</summary>
        public static object Get(object o, string key)
        {
            IDictionary d = Json.Unwrap(o) as IDictionary;
            if (d == null || key == null || !d.Contains(key)) return null;
            return d[key];
        }

        static bool IsNumber(object v) { return v is double || v is float || v is decimal || v is int || v is long || v is short || v is byte || v is uint || v is ulong || v is ushort || v is sbyte; }

        /// <summary>Number(v).</summary>
        public static double NumberOf(object value)
        {
            object v = Json.Unwrap(value);
            if (v == null) return 0;
            if (v is bool) return (bool)v ? 1 : 0;
            if (IsNumber(v)) return Convert.ToDouble(v, Inv);
            string s = v as string;
            if (s != null)
            {
                s = s.Trim();
                if (s.Length == 0) return 0;
                if (s.Length > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
                {
                    long hex;
                    return long.TryParse(s.Substring(2), NumberStyles.AllowHexSpecifier, Inv, out hex) ? hex : double.NaN;
                }
                foreach (char c in s) if (!(char.IsDigit(c) && c < 128) && c != '.' && c != '-' && c != '+' && c != 'e' && c != 'E') return s == "Infinity" || s == "+Infinity" ? double.PositiveInfinity : s == "-Infinity" ? double.NegativeInfinity : double.NaN;
                double d;
                return double.TryParse(s, NumberStyles.Float, Inv, out d) ? d : double.NaN;
            }
            return double.NaN;
        }

        /// <summary>feed.js num(): a finite number, or a string that holds one; else null.</summary>
        public static object Num(object value)
        {
            object v = Json.Unwrap(value);
            if (v == null || v is bool) return null;
            if (IsNumber(v)) { double d = Convert.ToDouble(v, Inv); return (double.IsNaN(d) || double.IsInfinity(d)) ? null : (object)d; }
            string s = v as string;
            if (s == null || s.Trim().Length == 0) return null;
            double n = NumberOf(s);
            return (double.IsNaN(n) || double.IsInfinity(n)) ? null : (object)n;
        }

        /// <summary>Math.round.</summary>
        public static double Round(double d) { return Math.Floor(d + 0.5); }

        /// <summary>feed.js int(): Math.round(num(v)), or null.</summary>
        public static object Int(object v)
        {
            object n = Num(v);
            if (n == null) return null;
            double r = Round((double)n);
            if (Math.Abs(r) < 9.0e18) return (long)r;
            return r;
        }

        /// <summary>feed.js frac(): num(v) rounded to 4 decimals, or null.</summary>
        public static object Frac(object v)
        {
            object n = Num(v);
            if (n == null) return null;
            return Round((double)n * 10000) / 10000;
        }

        /// <summary>a / b as JavaScript divides (Number() of each).</summary>
        public static double Div(object a, object b) { return NumberOf(a) / NumberOf(b); }

        /// <summary>Truthiness.</summary>
        public static bool Truthy(object value)
        {
            object v = Json.Unwrap(value);
            if (v == null) return false;
            if (v is bool) return (bool)v;
            if (IsNumber(v)) { double d = Convert.ToDouble(v, Inv); return d != 0 && !double.IsNaN(d); }
            string s = v as string;
            if (s != null) return s.Length > 0;
            return true;
        }

        /// <summary>!!Number(v).</summary>
        public static bool Bool(object v) { double d = NumberOf(v); return d != 0 && !double.IsNaN(d); }

        /// <summary>String(v).</summary>
        public static string JsString(object value)
        {
            object v = Json.Unwrap(value);
            if (v == null) return "null";
            string s = v as string;
            if (s != null) return s;
            if (v is bool) return (bool)v ? "true" : "false";
            if (IsNumber(v)) return NumberText(Convert.ToDouble(v, Inv));
            if (v is IDictionary) return "[object Object]";
            IEnumerable list = v as IEnumerable;
            if (list != null)
            {
                List<string> parts = new List<string>();
                foreach (object o in list) { object x = Json.Unwrap(o); parts.Add(x == null ? "" : JsString(x)); }
                return string.Join(",", parts.ToArray());
            }
            return Convert.ToString(v, Inv);
        }

        /// <summary>`${v}` in a template string: undefined (here, null) reads "undefined".</summary>
        public static string Tpl(object v) { return Json.Unwrap(v) == null ? "undefined" : JsString(v); }

        /// <summary>feed.js str(): null for null or "", else String(v) cut to max UTF-16 units.</summary>
        public static string Str(object value, int max)
        {
            object v = Json.Unwrap(value);
            if (v == null) return null;
            string s = v as string;
            if (s != null && s.Length == 0) return null;
            s = JsString(v);
            return s.Length > max ? s.Substring(0, max) : s;
        }
        public static string Str(object value) { return Str(value, 120); }

        /// <summary>Number to text as JavaScript prints it (the shortest form .NET gives, in JavaScript's layout).</summary>
        public static string NumberText(double d)
        {
            if (double.IsNaN(d) || double.IsInfinity(d)) return "null";
            if (d == 0) return "0";
            if (d == Math.Floor(d) && Math.Abs(d) < 9.0e15) return ((long)d).ToString(Inv);
            // The shortest digits that read back as the same double, as JavaScript prints (older .NET's "R" may not be).
            string r = null;
            for (int p = 1; p <= 17 && r == null; p++)
            {
                string t = d.ToString("E" + (p - 1).ToString(Inv), Inv);
                double back;
                if (double.TryParse(t, NumberStyles.Float, Inv, out back) && back == d) r = t;
            }
            if (r == null) r = d.ToString("R", Inv);
            bool neg = r.StartsWith("-");
            if (neg) r = r.Substring(1);
            int e = 0;
            int ePos = r.IndexOfAny(new char[] { 'E', 'e' });
            if (ePos >= 0) { e = int.Parse(r.Substring(ePos + 1), Inv); r = r.Substring(0, ePos); }
            int dot = r.IndexOf('.');
            string digits = dot >= 0 ? r.Remove(dot, 1) : r;
            int pointAt = (dot >= 0 ? dot : r.Length) + e;   // digits[0..pointAt) are the integer part
            int lead = 0;
            while (lead < digits.Length - 1 && digits[lead] == '0') { lead++; pointAt--; }
            digits = digits.Substring(lead).TrimEnd('0');
            if (digits.Length == 0) return "0";
            int k = digits.Length, n = pointAt;
            string outText;
            if (k <= n && n <= 21) outText = digits + new string('0', n - k);
            else if (0 < n && n <= 21) outText = digits.Substring(0, n) + "." + digits.Substring(n);
            else if (-6 < n && n <= 0) outText = "0." + new string('0', -n) + digits;
            else
            {
                int exp = n - 1;
                outText = digits.Substring(0, 1) + (k > 1 ? "." + digits.Substring(1) : "") + "e" + (exp >= 0 ? "+" : "-") + Math.Abs(exp).ToString(Inv);
            }
            return neg ? "-" + outText : outText;
        }

        /// <summary>a.localeCompare(b), as near as .NET gets: en-US, hyphens not ignored.</summary>
        public static int Compare(string a, string b) { return Math.Sign(Collation.Compare(a ?? "", b ?? "", CompareOptions.StringSort)); }

        /// <summary>feed.js hostOnly(): the host name alone (no scheme, port, path or user info), "" when there is none.</summary>
        public static string HostOnly(string host)
        {
            string h = (host ?? "").Trim();
            if (h.Length == 0) return "";
            if (!Regex.IsMatch(h, "^[a-zA-Z][a-zA-Z0-9+.-]*://")) h = "https://" + h;
            Uri u;
            if (!Uri.TryCreate(h, UriKind.Absolute, out u)) return "";
            string name = u.HostNameType == UriHostNameType.Dns ? u.IdnHost : u.Host;
            name = name.Trim('[', ']').ToLowerInvariant();
            IPAddress ip;
            // IPv6 in its short form, as a WHATWG URL gives it (older .NET writes every group out).
            if (u.HostNameType == UriHostNameType.IPv6 && IPAddress.TryParse(name, out ip)) name = ip.ToString().ToLowerInvariant();
            return name;
        }

        /// <summary>feed.js tagsOf(): Proxmox VE writes "a;b,c" (older: spaces), a Datacenter Manager an array.</summary>
        public static object[] Tags(object value)
        {
            object t = Json.Unwrap(value);
            List<string> raw = new List<string>();
            if (t is object[] || (t is IList && !(t is string)))
            {
                foreach (object o in (IEnumerable)t) raw.Add(JsString(o));
            }
            else raw.AddRange(Regex.Split(Truthy(t) ? JsString(t) : "", "[;, ]+"));
            List<object> outList = new List<object>();
            foreach (string x in raw)
            {
                string y = x.Trim();
                if (y.Length == 0) continue;
                if (outList.Count >= 12) break;
                outList.Add(y.Length > 40 ? y.Substring(0, 40) : y);
            }
            return outList.ToArray();
        }

        /// <summary>feed.js loadOf(): the first three load averages to two decimals, or null.</summary>
        public static object Load(object value)
        {
            object l = Json.Unwrap(value);
            if (!(l is object[] || (l is IList && !(l is string)))) return null;
            List<object> outList = new List<object>();
            foreach (object x in (IEnumerable)l)
            {
                if (outList.Count >= 3) break;
                object n = Num(x);
                outList.Add(n == null ? null : (object)(Round((double)n * 100) / 100));
            }
            return outList.ToArray();
        }

        /// <summary>feed.js versionOf(): "9.2.1" out of "pve-manager/9.2.1/abc", or null.</summary>
        public static string Version(object v)
        {
            Match m = Regex.Match(Truthy(v) ? JsString(v) : "", "([0-9]+\\.[0-9]+(?:\\.[0-9]+)?)");
            return m.Success ? m.Groups[1].Value : null;
        }

        // ---- sorting as Array.prototype.sort does with the plugin's comparators (stable) ----
        static object[] StableSort(object[] rows, Comparison<int> cmp)
        {
            int[] idx = new int[rows.Length];
            for (int i = 0; i < idx.Length; i++) idx[i] = i;
            int[] tmp = new int[idx.Length];
            MergeSort(idx, tmp, 0, idx.Length, cmp);
            object[] outRows = new object[rows.Length];
            for (int i = 0; i < idx.Length; i++) outRows[i] = rows[idx[i]];
            return outRows;
        }
        static void MergeSort(int[] a, int[] tmp, int lo, int hi, Comparison<int> cmp)
        {
            if (hi - lo < 2) return;
            int mid = (lo + hi) / 2;
            MergeSort(a, tmp, lo, mid, cmp);
            MergeSort(a, tmp, mid, hi, cmp);
            int i = lo, j = mid, k = lo;
            while (i < mid && j < hi) tmp[k++] = cmp(a[j], a[i]) < 0 ? a[j++] : a[i++];
            while (i < mid) tmp[k++] = a[i++];
            while (j < hi) tmp[k++] = a[j++];
            Array.Copy(tmp, lo, a, lo, hi - lo);
        }
        static int Sign(double d) { return double.IsNaN(d) ? 0 : Math.Sign(d); }
        static double OrZero(object v) { return Truthy(v) ? NumberOf(v) : 0; }
        static string OrEmpty(object v) { return Truthy(v) ? JsString(v) : ""; }

        /// <summary>Nodes in the file: by `${remote || ""}/${node}`.</summary>
        public static object[] SortNodes(object[] rows)
        {
            string[] k = new string[rows.Length];
            for (int i = 0; i < rows.Length; i++) k[i] = OrEmpty(Get(rows[i], "remote")) + "/" + Tpl(Get(rows[i], "node"));
            return StableSort(rows, delegate(int a, int b) { return Compare(k[a], k[b]); });
        }
        /// <summary>The plugin's nodesOf(): by remote/node through a Datacenter Manager, else by node.</summary>
        public static object[] SortNodeKeys(object[] rows)
        {
            string[] k = new string[rows.Length];
            for (int i = 0; i < rows.Length; i++) { object rem = Get(rows[i], "remote"); k[i] = Truthy(rem) ? JsString(rem) + "/" + Tpl(Get(rows[i], "node")) : Tpl(Get(rows[i], "node")); }
            return StableSort(rows, delegate(int a, int b) { return Compare(k[a], k[b]); });
        }
        /// <summary>Guests: by remote, then vmid.</summary>
        public static object[] SortGuests(object[] rows)
        {
            string[] k = new string[rows.Length];
            double[] n = new double[rows.Length];
            for (int i = 0; i < rows.Length; i++) { k[i] = OrEmpty(Get(rows[i], "remote")); n[i] = NumberOf(Get(rows[i], "vmid")); }
            return StableSort(rows, delegate(int a, int b) { int c = Compare(k[a], k[b]); return c != 0 ? c : Sign(n[a] - n[b]); });
        }
        /// <summary>Newest first by a number field: (b[f] || 0) - (a[f] || 0).</summary>
        public static object[] SortDesc(object[] rows, string field)
        {
            double[] n = new double[rows.Length];
            for (int i = 0; i < rows.Length; i++) n[i] = OrZero(Get(rows[i], field));
            return StableSort(rows, delegate(int a, int b) { return Sign(n[b] - n[a]); });
        }
        /// <summary>A to Z by String(x[field]).</summary>
        public static object[] SortByText(object[] rows, string field)
        {
            string[] k = new string[rows.Length];
            for (int i = 0; i < rows.Length; i++) k[i] = Tpl(Get(rows[i], field));
            return StableSort(rows, delegate(int a, int b) { return Compare(k[a], k[b]); });
        }
    }

    /// <summary>What one HTTPS request did. Never holds the token.</summary>
    public sealed class Result
    {
        public int Status;
        public string Reason;
        public string Body;
        public string Error;
        public bool CertSeen;
        public bool CertAccepted;
        public bool CertTrustedByWindows;
        public string Fingerprint;
        public string Subject;
        public string Issuer;
        public string NotAfter;
        public long Ms;
    }

    /// <summary>GET over HTTPS with a certificate check that belongs to this one request: never process-wide.</summary>
    public static class Http
    {
        const int MaxBody = 32 * 1024 * 1024;

        /// <summary>SHA-256 of the certificate, "AB:CD:..." as Proxmox shows it.</summary>
        public static string Fingerprint(byte[] raw)
        {
            using (SHA256 sha = SHA256.Create())
            {
                byte[] h = sha.ComputeHash(raw);
                StringBuilder sb = new StringBuilder();
                for (int i = 0; i < h.Length; i++) { if (i > 0) sb.Append(':'); sb.Append(h[i].ToString("X2")); }
                return sb.ToString();
            }
        }

        /// <summary>A fingerprint as typed or pasted: hex digits only, upper case.</summary>
        public static string NormalizePin(string pin)
        {
            if (string.IsNullOrEmpty(pin)) return "";
            StringBuilder sb = new StringBuilder();
            foreach (char c in pin) if (Uri.IsHexDigit(c)) sb.Append(char.ToUpperInvariant(c));
            return sb.Length == 64 ? sb.ToString() : "";
        }

        static string UrlHost(string host) { return host.Contains(":") && !host.StartsWith("[") ? "[" + host + "]" : host; }

        /// <summary>
        /// One GET to https://host:port/api2/json + path. The certificate is accepted only when its SHA-256 fingerprint
        /// equals pin, or (trustWindows) when Windows trusts it for that host name. fresh: a connection of its own, so
        /// setup always sees the certificate. Never throws: Error says what went wrong.
        /// </summary>
        public static Result Get(string host, int port, string path, string auth, string pin, bool trustWindows, int timeoutMs, bool fresh)
        {
            Result r = new Result();
            DateTime t0 = DateTime.UtcNow;
            string want = NormalizePin(pin);
            HttpWebResponse resp = null;
            try
            {
                if (string.IsNullOrEmpty(host)) { r.Error = "Bad host: none"; return r; }
                Uri uri;
                if (!Uri.TryCreate("https://" + UrlHost(host) + ":" + port.ToString(CultureInfo.InvariantCulture) + "/api2/json" + path, UriKind.Absolute, out uri)) { r.Error = "Bad host: " + host; return r; }
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create(uri);
                req.Method = "GET";
                req.Accept = "application/json";
                req.Timeout = timeoutMs;
                req.ReadWriteTimeout = timeoutMs;
                req.AllowAutoRedirect = false;
                req.Proxy = null;   // straight to the server, as the plugin does
                req.UserAgent = "ProxmoxLink";
                if (!string.IsNullOrEmpty(auth)) req.Headers[HttpRequestHeader.Authorization] = auth;
                // Pooled connections are only shared between requests that trust exactly the same certificate.
                req.ConnectionGroupName = fresh ? "pxl-" + Guid.NewGuid().ToString("N") : "pxl-" + want + (trustWindows ? "-w" : "");
                req.ServerCertificateValidationCallback = delegate(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors)
                {
                    r.CertSeen = true;
                    if (cert == null) return false;
                    r.Fingerprint = Fingerprint(cert.GetRawCertData());
                    r.Subject = cert.Subject;
                    r.Issuer = cert.Issuer;
                    try { r.NotAfter = cert.GetExpirationDateString(); } catch (Exception) { r.NotAfter = null; }
                    r.CertTrustedByWindows = errors == SslPolicyErrors.None;
                    bool ok = (want.Length > 0 && NormalizePin(r.Fingerprint) == want) || (trustWindows && r.CertTrustedByWindows);
                    r.CertAccepted = ok;
                    return ok;
                };
                try { resp = (HttpWebResponse)req.GetResponse(); }
                catch (WebException we)
                {
                    resp = we.Response as HttpWebResponse;
                    if (resp == null) { r.Error = Describe(we, r); return r; }
                }
                r.Status = (int)resp.StatusCode;
                r.Reason = resp.StatusDescription;
                r.Body = ReadBody(resp);
                if (r.Status >= 400) r.Error = ("HTTP " + r.Status.ToString(CultureInfo.InvariantCulture) + " " + (r.Reason ?? "")).Trim();
                else if (r.Status >= 300) r.Error = "HTTP " + r.Status.ToString(CultureInfo.InvariantCulture) + " redirect";
                return r;
            }
            catch (Exception e) { r.Error = Describe(e, r); return r; }
            finally
            {
                if (resp != null) { try { resp.Close(); } catch (Exception) { } }
                r.Ms = (long)(DateTime.UtcNow - t0).TotalMilliseconds;
            }
        }

        static string ReadBody(HttpWebResponse resp)
        {
            using (Stream s = resp.GetResponseStream())
            using (StreamReader rd = new StreamReader(s, new UTF8Encoding(false)))
            {
                char[] buf = new char[8192];
                StringBuilder sb = new StringBuilder();
                int n;
                while ((n = rd.Read(buf, 0, buf.Length)) > 0)
                {
                    sb.Append(buf, 0, n);
                    if (sb.Length > MaxBody) throw new InvalidDataException("Response too large");
                }
                return sb.ToString();
            }
        }

        /// <summary>Errors in the words the plugin's friendlyError() turns into its short messages.</summary>
        static string Describe(Exception e, Result r)
        {
            if (r.CertSeen && !r.CertAccepted) return "certificate not trusted";
            for (Exception x = e; x != null; x = x.InnerException)
            {
                SocketException se = x as SocketException;
                if (se == null) continue;
                switch (se.SocketErrorCode)
                {
                    case SocketError.ConnectionRefused: return "connect ECONNREFUSED";
                    case SocketError.HostNotFound:
                    case SocketError.NoData:
                    case SocketError.TryAgain: return "getaddrinfo ENOTFOUND";
                    case SocketError.TimedOut: return "Timeout";
                    case SocketError.HostUnreachable:
                    case SocketError.NetworkUnreachable:
                    case SocketError.HostDown:
                    case SocketError.NetworkDown: return "Unreachable";
                    case SocketError.ConnectionReset:
                    case SocketError.ConnectionAborted: return "Connection reset";
                }
            }
            for (Exception x = e; x != null; x = x.InnerException) if (x is AuthenticationException) return "TLS error";
            WebException we = e as WebException;
            if (we != null)
            {
                switch (we.Status)
                {
                    case WebExceptionStatus.Timeout: return "Timeout";
                    case WebExceptionStatus.NameResolutionFailure: return "getaddrinfo ENOTFOUND";
                    case WebExceptionStatus.ConnectFailure: return "Connect failed";
                    case WebExceptionStatus.TrustFailure: return "certificate not trusted";
                    case WebExceptionStatus.SecureChannelFailure: return "TLS error";
                    case WebExceptionStatus.ConnectionClosed:
                    case WebExceptionStatus.KeepAliveFailure:
                    case WebExceptionStatus.ReceiveFailure:
                    case WebExceptionStatus.SendFailure: return "Connection reset";
                }
            }
            if (e is InvalidDataException) return e.Message;
            return e.Message ?? "Failed";
        }
    }

    /// <summary>A small rolling log (256 KB, three old files kept). Known secrets are masked before anything is written.</summary>
    public static class Log
    {
        static readonly object Gate = new object();
        static string path;
        static readonly List<string> secrets = new List<string>();
        public static string FilePath { get { return path; } }

        public static void Init(string dir)
        {
            lock (Gate) { Directory.CreateDirectory(dir); path = Path.Combine(dir, "ProxmoxLink.log"); }
        }
        public static void AddSecret(string s)
        {
            if (string.IsNullOrEmpty(s) || s.Length < 4) return;
            lock (Gate) { if (!secrets.Contains(s)) secrets.Add(s); }
        }
        public static void Write(string level, string message)
        {
            lock (Gate)
            {
                if (path == null) return;
                string m = message ?? "";
                foreach (string s in secrets) m = m.Replace(s, "***");
                m = m.Replace("\r", " ").Replace("\n", " ");
                try
                {
                    FileInfo fi = new FileInfo(path);
                    if (fi.Exists && fi.Length > 256 * 1024) Roll();
                    byte[] b = new UTF8Encoding(false).GetBytes(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) + " " + level + " " + m + "\r\n");
                    using (FileStream fs = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete)) fs.Write(b, 0, b.Length);
                }
                catch (Exception) { }
            }
        }
        static void Roll()
        {
            for (int i = 3; i >= 1; i--)
            {
                string from = i == 1 ? path : path + "." + (i - 1).ToString(CultureInfo.InvariantCulture);
                string to = path + "." + i.ToString(CultureInfo.InvariantCulture);
                try { if (File.Exists(to)) File.Delete(to); if (File.Exists(from)) File.Move(from, to); } catch (Exception) { }
            }
        }
    }
}
'@

if (-not ('ProxmoxLink.Json' -as [type])) {
    Add-Type -TypeDefinition $script:PxCSharp -Language CSharp -IgnoreWarnings -ErrorAction Stop
}
if ($PSVersionTable.PSEdition -ne 'Core') { Add-Type -AssemblyName System.Security }
elseif (-not ('System.Security.Cryptography.ProtectedData' -as [type])) { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData }
$J = [ProxmoxLink.Js]

# TLS 1.2 or later for this process's own requests. Windows PowerShell 5.1 would otherwise still offer TLS 1.0.
try {
    $tls = [Net.SecurityProtocolType]::Tls12
    if ([enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') { $tls = $tls -bor [Net.SecurityProtocolType]::Tls13 }
    [Net.ServicePointManager]::SecurityProtocol = $tls
} catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }

# ---------------------------------------------------------------------------------------------------------------------
# Places
# ---------------------------------------------------------------------------------------------------------------------
function Get-PxPaths {
    $roaming = if ($env:APPDATA) { $env:APPDATA } else { [Environment]::GetFolderPath('ApplicationData') }
    $local = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [Environment]::GetFolderPath('LocalApplicationData') }
    $configDir = Join-Path $local 'ProxmoxLink'
    # One Proxmox Link per settings folder (and so per Windows user): the names below come from that folder.
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($configDir.ToLowerInvariant())) } finally { $sha.Dispose() }
    $id = (($hash[0..5] | ForEach-Object { $_.ToString('x2') }) -join '')
    [pscustomobject]@{
        StateDir      = Join-Path $roaming 'ProxmoxControl'
        StateFile     = Join-Path (Join-Path $roaming 'ProxmoxControl') 'state.json'
        CompanionFile = Join-Path (Join-Path $roaming 'ProxmoxControl') 'companion.json'
        ConfigDir     = $configDir
        ConfigFile    = Join-Path $configDir 'config.json'
        LogDir        = Join-Path $configDir 'logs'
        MutexName     = "Local\ProxmoxLink-$id"
        QuitEventName = "Local\ProxmoxLink-$id-quit"
        SetupMutexName = "Local\ProxmoxLink-$id-setup"
    }
}

function Write-PxLog([string]$Level, [string]$Message) { [ProxmoxLink.Log]::Write($Level, $Message) }

# ---------------------------------------------------------------------------------------------------------------------
# Settings: %LOCALAPPDATA%\ProxmoxLink\config.json (not in ProxmoxControl, which the widget can read)
# ---------------------------------------------------------------------------------------------------------------------
$script:PxEntropy = [Text.Encoding]::UTF8.GetBytes('ProxmoxLink token secret v1')

function Protect-PxSecret([string]$Plain) {
    if ([string]::IsNullOrEmpty($Plain)) { return '' }
    $bytes = [Text.Encoding]::UTF8.GetBytes($Plain)
    $blob = [Security.Cryptography.ProtectedData]::Protect($bytes, $script:PxEntropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return 'dpapi:' + [Convert]::ToBase64String($blob)
}

function Unprotect-PxSecret([string]$Stored) {
    if ([string]::IsNullOrEmpty($Stored) -or -not $Stored.StartsWith('dpapi:')) { return $null }
    try {
        $blob = [Convert]::FromBase64String($Stored.Substring(6))
        $bytes = [Security.Cryptography.ProtectedData]::Unprotect($blob, $script:PxEntropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [Text.Encoding]::UTF8.GetString($bytes)
    } catch { return $null }
}

function New-PxConnectionConfig([string]$Key, [string]$Kind) {
    [ordered]@{ key = $Key; kind = $Kind; label = ''; host = ''; port = $script:PxDefaultPort[$Kind]; tokenId = ''; secret = ''; fingerprint = ''; trustWindows = $false }
}

function New-PxConfig {
    [ordered]@{
        version     = 1
        interval    = 30
        connections = @((New-PxConnectionConfig 'A' 'pve'), (New-PxConnectionConfig 'B' 'pve'), (New-PxConnectionConfig 'C' 'pbs'))
    }
}

<# A SHA-256 fingerprint as Proxmox shows it, "AB:CD:...", or "" when it is not one. #>
function Format-PxFingerprint([string]$Text) {
    $hex = [ProxmoxLink.Http]::NormalizePin($Text)
    if (-not $hex) { return '' }
    return ($hex -replace '(..)(?!$)', '$1:')
}

function ConvertTo-PxInterval($Value) {
    $n = $J::Num($Value)
    if ($null -eq $n) { return 30 }
    return [int][Math]::Min(60, [Math]::Max(5, [Math]::Round([double]$n)))
}

<# Reads config.json into the shape New-PxConfig makes; anything missing or odd falls back to the defaults. #>
function Read-PxConfig([string]$Path = (Get-PxPaths).ConfigFile) {
    $cfg = New-PxConfig
    if (-not (Test-Path -LiteralPath $Path)) { return $cfg }
    try { $raw = [ProxmoxLink.Json]::Parse([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)) } catch { Write-PxLog 'warn' "settings unreadable: $($_.Exception.Message)"; return $cfg }
    $cfg.interval = ConvertTo-PxInterval $J::Get($raw, 'interval')
    foreach ($c in @($J::Get($raw, 'connections'))) {
        $key = [string]$J::Get($c, 'key')
        $i = [Array]::IndexOf($script:PxKeys, $key)
        if ($i -lt 0) { continue }
        $kind = [string]$J::Get($c, 'kind')
        if ($script:PxKinds -notcontains $kind) { $kind = $cfg.connections[$i].kind }
        $port = $J::Int($J::Get($c, 'port'))
        if ($null -eq $port -or $port -lt 1 -or $port -gt 65535) { $port = $script:PxDefaultPort[$kind] }
        $o = New-PxConnectionConfig $key $kind
        $o.label = [string]$J::Get($c, 'label')
        $o.host = ([string]$J::Get($c, 'host')).Trim()
        $o.port = [int]$port
        $o.tokenId = ([string]$J::Get($c, 'tokenId')).Trim()
        $o.secret = [string]$J::Get($c, 'secret')
        $o.fingerprint = Format-PxFingerprint ([string]$J::Get($c, 'fingerprint'))
        $o.trustWindows = $J::Truthy($J::Get($c, 'trustWindows'))
        $cfg.connections[$i] = $o
    }
    return $cfg
}

<# Writes config.json whole. Secrets must already be protected ("dpapi:..."); a plain one is refused. #>
function Save-PxConfig($Config, [string]$Path = (Get-PxPaths).ConfigFile) {
    foreach ($c in $Config.connections) {
        if ($c.secret -and -not ([string]$c.secret).StartsWith('dpapi:')) { throw 'A token secret must be protected before it is saved.' }
    }
    $dir = Split-Path -Parent $Path
    [void][IO.Directory]::CreateDirectory($dir)
    $text = Format-PxJson ([ProxmoxLink.Json]::Stringify($Config))
    $how = Write-PxFileWhole -Dir $dir -Name (Split-Path -Leaf $Path) -Text $text
    if ($how -eq 'failed' -or $how -eq 'held') { throw "Could not write $Path" }
}

<# Indents compact JSON for a settings file people may open. #>
function Format-PxJson([string]$Json) {
    $sb = New-Object Text.StringBuilder
    $indent = 0; $inString = $false; $escape = $false
    foreach ($ch in $Json.ToCharArray()) {
        if ($inString) {
            [void]$sb.Append($ch)
            if ($escape) { $escape = $false } elseif ($ch -eq '\') { $escape = $true } elseif ($ch -eq '"') { $inString = $false }
            continue
        }
        switch ($ch) {
            '"' { $inString = $true; [void]$sb.Append($ch) }
            { $_ -eq '{' -or $_ -eq '[' } { $indent++; [void]$sb.Append($ch).Append("`r`n").Append('  ' * $indent) }
            { $_ -eq '}' -or $_ -eq ']' } { $indent--; [void]$sb.Append("`r`n").Append('  ' * $indent).Append($ch) }
            ',' { [void]$sb.Append($ch).Append("`r`n").Append('  ' * $indent) }
            ':' { [void]$sb.Append(': ') }
            default { [void]$sb.Append($ch) }
        }
    }
    return ($sb.ToString() -replace '\{\s+\}', '{}' -replace '\[\s+\]', '[]') + "`r`n"
}

<# A connection as the poller uses it: the secret decrypted (kept in memory only). #>
function Get-PxRuntimeConnection($C) {
    $secret = Unprotect-PxSecret $C.secret
    $hostName = ([string]$C.host).Trim()
    [pscustomobject]@{
        key          = $C.key
        kind         = $C.kind
        label        = [string]$C.label
        host         = $hostName
        port         = [int]$C.port
        tokenId      = [string]$C.tokenId
        secret       = $secret
        pin          = [string]$C.fingerprint
        trustWindows = [bool]$C.trustWindows
        configured   = [bool]($hostName -and $C.tokenId -and $secret)
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# The Proxmox API
# ---------------------------------------------------------------------------------------------------------------------
<# Proxmox VE: PVEAPIToken=user@realm!name=secret. Backup Server and Datacenter Manager use a colon. #>
function Get-PxAuthHeader($Conn) {
    switch ($Conn.kind) {
        'pbs' { return "PBSAPIToken=$($Conn.tokenId):$($Conn.secret)" }
        'pdm' { return "PDMAPIToken=$($Conn.tokenId):$($Conn.secret)" }
        default { return "PVEAPIToken=$($Conn.tokenId)=$($Conn.secret)" }
    }
}

<# One GET. Returns the answer's "data"; throws the error text (the plugin's words) on failure. #>
function Invoke-PxApi($Conn, [string]$Path, [int]$TimeoutMs = 8000) {
    $r = [ProxmoxLink.Http]::Get($Conn.host, $Conn.port, $Path, (Get-PxAuthHeader $Conn), $Conn.pin, $Conn.trustWindows, $TimeoutMs, $false)
    $shown = "GET $($Conn.host):$($Conn.port)/api2/json$($Path.Split('?')[0])"
    if ($r.Error) {
        if ($r.Status -ge 400) { Write-PxLog 'warn' "$shown -> $($r.Status) $($r.Reason)" }
        elseif ($r.CertSeen -and -not $r.CertAccepted) { Write-PxLog 'warn' "$shown failed: certificate not trusted (SHA-256 $($r.Fingerprint))" }
        else { Write-PxLog 'warn' "$shown failed: $($r.Error)" }
        throw $r.Error
    }
    $body = if ($r.Body) { $r.Body } else { '{}' }
    try { $json = [ProxmoxLink.Json]::Parse($body) } catch { throw 'Bad JSON from Proxmox' }
    return , ($J::Get($json, 'data'))
}

<# The plugin's friendlyError(): the short words the widget shows. #>
function Get-PxFriendlyError([string]$Message) {
    $m = [string]$Message
    if ($m -cmatch '401') { return 'Auth failed' }
    if ($m -cmatch '403') { return 'No permission' }
    if ($m -cmatch 'ENOTFOUND|EAI_AGAIN') { return 'DNS failed' }
    if ($m -cmatch 'ECONNREFUSED') { return 'Refused' }
    if ($m -match 'Timeout|ETIMEDOUT') { return 'Timeout' }
    if ($m -match 'CERT|certificate|self.signed') { return 'TLS cert' }
    if ($m -cmatch 'Bad host') { return 'Bad host' }
    return $m.Substring(0, [Math]::Min(18, $m.Length))
}

function Get-PxList($Value) {
    $out = New-Object 'System.Collections.Generic.List[object]'
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and $Value -isnot [System.Collections.IDictionary]) {
        foreach ($x in $Value) { if ($x -is [System.Collections.IDictionary]) { $out.Add($x) } }
    }
    return , $out.ToArray()
}

function Assert-PxBudget([datetime]$Start, [int]$BudgetMs) {
    if (([datetime]::UtcNow - $Start).TotalMilliseconds -gt $BudgetMs) { throw 'poll timeout' }
}
function Get-PxTimeLeft([datetime]$Start, [int]$BudgetMs) {
    return [int][Math]::Max(1000, [Math]::Min(8000, $BudgetMs - ([datetime]::UtcNow - $Start).TotalMilliseconds))
}

<# A Backup Server: node status and datastore usage each poll; GC, tasks and each datastore's groups (every 60 s) as far as
   the token's rights go. As the plugin's pollPbs(), one call after another. #>
function Invoke-PxPollPbs($Conn, $State) {
    $t0 = [datetime]::UtcNow; $budget = 20000
    $enc = [Uri]::EscapeDataString
    try { $status = Invoke-PxApi $Conn '/nodes/localhost/status' (Get-PxTimeLeft $t0 $budget) }
    catch { $status = @{ error = (Get-PxFriendlyError $_.Exception.Message) } }
    Assert-PxBudget $t0 $budget
    $usage = Invoke-PxApi $Conn '/status/datastore-usage' (Get-PxTimeLeft $t0 $budget)
    if ($null -eq $State.pbs) { Write-PxLog 'info' "PBS $($Conn.key): $(@(Get-PxList $usage).Count) datastore(s)$(if ($J::Get($status, 'error')) { ', node status: ' + $J::Get($status, 'error') })" }
    $gc = $null; $tasks = $null; $recent = $null
    Assert-PxBudget $t0 $budget
    try { $gc = Invoke-PxApi $Conn '/admin/gc' (Get-PxTimeLeft $t0 $budget) } catch { }
    Assert-PxBudget $t0 $budget
    try { $tasks = Invoke-PxApi $Conn '/nodes/localhost/tasks?running=true&limit=100' (Get-PxTimeLeft $t0 $budget) } catch { }
    Assert-PxBudget $t0 $budget
    try { $recent = Invoke-PxApi $Conn '/nodes/localhost/tasks?limit=12' (Get-PxTimeLeft $t0 $budget) } catch { }
    $prev = $State.pbs
    $groups = New-Object System.Collections.Specialized.OrderedDictionary
    $groupsAt = 0
    if ($prev) { foreach ($k in $prev.groups.Keys) { $groups[$k] = $prev.groups[$k] }; $groupsAt = $prev.groupsAt }
    $now = $J::Now()
    $refresh = ($now - $groupsAt) -gt 60000
    if ($refresh) {
        foreach ($ds in (Get-PxList $usage)) {
            $store = $J::JsString($ds['store'])
            Assert-PxBudget $t0 $budget
            try { $groups[$store] = Invoke-PxApi $Conn ('/admin/datastore/' + $enc.Invoke($store) + '/groups') (Get-PxTimeLeft $t0 $budget) }
            catch { if (-not $groups.Contains($store)) { $groups[$store] = $null } }
        }
    }
    $gcBy = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
    foreach ($g in (Get-PxList $gc)) { $gcBy[$J::JsString($g['store'])] = $g }
    $recentDone = New-Object 'System.Collections.Generic.List[object]'
    foreach ($t in (Get-PxList $recent)) { if ($J::Truthy($t['endtime'])) { $recentDone.Add($t) } }
    $State.pbs = @{
        status   = $status
        usage    = (Get-PxList $usage)
        gc       = $gcBy
        tasks    = (Get-PxList $tasks)
        recent   = $recentDone.ToArray()
        groups   = $groups
        groupsAt = $(if ($refresh) { $J::Now() } else { $groupsAt })
    }
}

<# A Datacenter Manager: one list of every remote's resources, in Proxmox VE's shape with the remote on each, and the
   status totals. #>
function Invoke-PxPollPdm($Conn, $State, [int]$Interval) {
    $t0 = [datetime]::UtcNow; $budget = 20000
    $list = Invoke-PxApi $Conn "/resources/list?max-age=$Interval" (Get-PxTimeLeft $t0 $budget)
    Assert-PxBudget $t0 $budget
    $status = $null
    try { $status = Invoke-PxApi $Conn "/resources/status?max-age=$Interval" (Get-PxTimeLeft $t0 $budget) } catch { }
    $out = New-Object 'System.Collections.Generic.List[object]'
    $remotes = New-Object 'System.Collections.Generic.List[object]'
    foreach ($rem in (Get-PxList $list)) {
        $stores = New-Object 'System.Collections.Generic.List[object]'
        foreach ($r in (Get-PxList $rem['resources'])) {
            $type = ($(if ($J::Truthy($r['type'])) { $J::JsString($r['type']) } else { '' })) -creplace '^pve-', ''
            if ($type -ceq 'node' -or $type -ceq 'qemu' -or $type -ceq 'lxc' -or $type -ceq 'storage') {
                $x = $r.Clone()
                $x['type'] = $type; $x['remote'] = $rem['remote']; $x['template'] = $(if ($J::Truthy($r['template'])) { 1 } else { 0 })
                $out.Add($x)
            }
            if ($r['type'] -ceq 'pbs-datastore') {
                $name = if ($J::Truthy($r['name'])) { $r['name'] } elseif ($J::Truthy($r['store'])) { $r['store'] } else { ($(if ($J::Truthy($r['id'])) { $J::JsString($r['id']) } else { '' })).Split('/')[-1] }
                $stores.Add(@{ store = $name; used = $r['disk']; total = $r['maxdisk'] })
            }
        }
        $remotes.Add(@{ name = $rem['remote']; error = $(if ($J::Truthy($rem['error'])) { $J::JsString($rem['error']) } else { $null }); pbsStores = $stores.ToArray() })
    }
    if ($null -eq $State.resources) { Write-PxLog 'info' "PDM $($Conn.key): $(@(Get-PxList $list).Count) remote(s), $(@($out | Where-Object { $_['type'] -ceq 'node' }).Count) node(s)" }
    $State.resources = $out.ToArray()
    $State.pdmStatus = $status
    $State.pdmRemotes = $remotes.ToArray()
}

<# One poll of one connection, as the plugin's pollNow(). Errors become the plugin's short words; the last data stays. #>
function Invoke-PxPoll($Conn, $State, [int]$Interval) {
    try {
        if ($Conn.kind -eq 'pbs') { Invoke-PxPollPbs $Conn $State }
        elseif ($Conn.kind -eq 'pdm') { Invoke-PxPollPdm $Conn $State $Interval }
        else { $State.resources = Invoke-PxApi $Conn '/cluster/resources' 8000 }
        $State.error = $null; $State.updatedAt = $J::Now(); $State.failures = 0
    } catch {
        $State.error = Get-PxFriendlyError $_.Exception.Message
        $State.failures = [int]$State.failures + 1
        Write-PxLog 'warn' "poll $($Conn.key) failed: $($_.Exception.Message)"
    }
}

<# Proxmox VE's light extras for the widget: quorum and recent tasks every 30 s, each online node's load and version
   every 60 s (16 nodes at most). A call that is refused is left alone for 10 minutes. #>
function Invoke-PxPollExtras($Conn, $State) {
    if ($Conn.kind -ne 'pve' -or $State.error -or $null -eq $State.resources) { return $false }
    if ($null -eq $State.extras) { $State.extras = @{ cluster = $null; tasks = $null; loads = (New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)); at = @{} } }
    $ex = $State.extras
    $now = $J::Now()
    $due = { param($what) ($now - [long]$(if ($ex.at.ContainsKey($what)) { $ex.at[$what] } else { 0 })) -ge $script:PxExtraMs[$what] }
    if (-not ((& $due 'cluster') -or (& $due 'tasks') -or (& $due 'loads'))) { return $false }
    $refused = { param($what, $err) $ex.at[$what] = $now + $script:PxRefusedMs - $script:PxExtraMs[$what]; Write-PxLog 'warn' "feed: $what on $($Conn.key) failed: $err" }
    $loads = $ex.loads.Clone()   # a fresh copy: the writer may be reading the old one
    if (& $due 'cluster') {
        try {
            $list = Invoke-PxApi $Conn '/cluster/status'
            $ex.cluster = $null
            foreach ($r in (Get-PxList $list)) { if ($r['type'] -ceq 'cluster') { $ex.cluster = $r; break } }
            $ex.at['cluster'] = $now
        } catch { & $refused 'cluster' $_.Exception.Message }
    }
    if (& $due 'tasks') {
        try {
            $list = Get-PxList (Invoke-PxApi $Conn '/cluster/tasks')
            $sorted = $J::SortDesc($list, 'starttime')
            $ex.tasks = @($sorted | Select-Object -First 15)
            $ex.at['tasks'] = $now
        } catch { & $refused 'tasks' $_.Exception.Message }
    }
    if (& $due 'loads') {
        $ex.at['loads'] = $now
        $nodes = $J::SortNodeKeys((Get-PxNodeRows $State.resources))
        $online = @($nodes | Where-Object { $_['status'] -ceq 'online' } | Select-Object -First $script:PxMaxLoadNodes)
        foreach ($n in $online) {
            try {
                $s = Invoke-PxApi $Conn ('/nodes/' + [Uri]::EscapeDataString($J::JsString($n['node'])) + '/status')
                $loads[$J::Tpl($n['node'])] = @{ load = $J::Get($s, 'loadavg'); version = $J::Get($s, 'pveversion') }
            } catch { & $refused 'loads' $_.Exception.Message; break }
        }
    }
    $State.extras = @{ cluster = $ex.cluster; tasks = $ex.tasks; loads = $loads; at = $ex.at }
    return $true
}

function Get-PxNodeRows($Resources) {
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in (Get-PxList $Resources)) { if ($r['type'] -ceq 'node') { $out.Add($r) } }
    return , $out.ToArray()
}

# ---------------------------------------------------------------------------------------------------------------------
# The state file's pieces, from what the API returned: a line-for-line port of the plugin's src/feed.js
# ---------------------------------------------------------------------------------------------------------------------
function ConvertTo-PxNodeOut($R, $Extra) {
    $status = $J::Str($R['status'], 20)
    [ordered]@{
        name = $J::Str($R['node']); remote = $J::Str($R['remote']); status = $(if ($status) { $status } else { 'unknown' })
        cpu = $J::Frac($R['cpu']); cpus = $J::Int($R['maxcpu']); mem = $J::Int($R['mem']); maxmem = $J::Int($R['maxmem'])
        disk = $J::Int($R['disk']); maxdisk = $J::Int($R['maxdisk']); uptime = $J::Int($R['uptime'])
        load = $J::Load($J::Get($Extra, 'load')); version = $J::Version($J::Get($Extra, 'version'))
    }
}

function ConvertTo-PxGuestOut($R) {
    $status = $J::Str($R['status'], 20)
    [ordered]@{
        vmid = $J::Int($R['vmid']); name = $J::Str($R['name'], 80); type = $(if ($R['type'] -ceq 'lxc') { 'lxc' } else { 'qemu' })
        node = $J::Str($R['node']); remote = $J::Str($R['remote']); status = $(if ($status) { $status } else { 'unknown' })
        cpu = $J::Frac($R['cpu']); cpus = $J::Int($R['maxcpu']); mem = $J::Int($R['mem']); maxmem = $J::Int($R['maxmem'])
        disk = $J::Int($R['disk']); maxdisk = $J::Int($R['maxdisk']); uptime = $J::Int($R['uptime']); tags = $J::Tags($R['tags'])
        ha = $(if ($J::Truthy($R['hastate'])) { $J::Str($R['hastate'], 20) } else { $null })
        lock = $(if ($J::Truthy($R['lock'])) { $J::Str($R['lock'], 20) } else { $null })
    }
}

<# A shared storage appears once per node in /cluster/resources; it is listed once, with its node count. #>
function ConvertTo-PxStoragesOut($List) {
    $out = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
    foreach ($r in $List) {
        $shared = $J::Bool($r['shared'])
        $remote = if ($J::Truthy($r['remote'])) { $J::JsString($r['remote']) } else { '' }
        $key = $remote + '|' + $(if ($shared) { '' } else { $J::Tpl($r['node']) }) + '|' + $J::Tpl($r['storage'])
        if ($seen.ContainsKey($key)) { $seen[$key]['nodes'] = $seen[$key]['nodes'] + 1; continue }
        $s = [ordered]@{
            storage = $J::Str($r['storage']); node = $(if ($shared) { $null } else { $J::Str($r['node']) }); remote = $J::Str($r['remote'])
            shared = $shared; nodes = 1; type = $J::Str($r['plugintype'], 20); content = $J::Str($r['content'], 80)
            status = $J::Str($r['status'], 20); used = $J::Int($r['disk']); total = $J::Int($r['maxdisk'])
        }
        $seen[$key] = $s
        $out.Add($s)
    }
    return , $out.ToArray()
}

function ConvertTo-PxTaskOut($T) {
    [ordered]@{
        node = $J::Str($T['node'])
        type = $J::Str($(if ($J::Truthy($T['type'])) { $T['type'] } else { $T['worker_type'] }), 40)
        id = $J::Str($(if ($J::Truthy($T['id'])) { $T['id'] } else { $T['worker_id'] }), 80)
        status = $J::Str($T['status'], 80); start = $J::Int($T['starttime']); end = $J::Int($T['endtime'])
    }
}

function Select-PxFirst($Items, [int]$Count) {
    $a = @($Items)
    if ($a.Count -le $Count) { return , $a }
    return , $a[0..($Count - 1)]
}

function ConvertTo-PxPveOut($P, [bool]$IsPdm) {
    $res = Get-PxList $P.resources
    $ex = if ($P.extras) { $P.extras } else { @{} }
    $loads = if ($ex['loads']) { $ex['loads'] } else { @{} }
    $nodeRows = New-Object 'System.Collections.Generic.List[object]'
    $all = New-Object 'System.Collections.Generic.List[object]'
    $live = New-Object 'System.Collections.Generic.List[object]'
    $stor = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in $res) {
        $t = $r['type']
        if ($t -ceq 'node') { $nodeRows.Add($r) }
        elseif ($t -ceq 'qemu' -or $t -ceq 'lxc') { $all.Add($r); if (-not $J::Truthy($r['template'])) { $live.Add($r) } }
        elseif ($t -ceq 'storage') { $stor.Add($r) }
    }
    $nodes = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in (Select-PxFirst ($J::SortNodes($nodeRows.ToArray())) $script:PxCaps.nodes)) {
        $nodes.Add((ConvertTo-PxNodeOut $r $loads[$J::Tpl($r['node'])]))
    }
    $guests = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in (Select-PxFirst ($J::SortGuests($live.ToArray())) $script:PxCaps.guests)) { $guests.Add((ConvertTo-PxGuestOut $r)) }
    $out = [ordered]@{
        nodes = $nodes.ToArray(); guests = $guests.ToArray(); templates = [long]($all.Count - $live.Count)
        storages = (Select-PxFirst (ConvertTo-PxStoragesOut $stor.ToArray()) $script:PxCaps.storages)
    }
    if (-not $IsPdm) {
        $c = $ex['cluster']
        $out['cluster'] = $(if ($J::Truthy($c)) { [ordered]@{ name = $J::Str($J::Get($c, 'name')); quorate = $J::Bool($J::Get($c, 'quorate')); nodes = $J::Int($J::Get($c, 'nodes')) } } else { $null })
        if ($ex['tasks'] -is [array]) {
            $tasks = New-Object 'System.Collections.Generic.List[object]'
            foreach ($t in (Select-PxFirst (Get-PxList $ex['tasks']) $script:PxCaps.tasks)) { $tasks.Add((ConvertTo-PxTaskOut $t)) }
            $out['tasks'] = $tasks.ToArray()
        } else { $out['tasks'] = $null }
    }
    return $out
}

function ConvertTo-PxPdmOut($P) {
    $out = ConvertTo-PxPveOut $P $true
    $status = $P.pdmStatus
    $types = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
    foreach ($r in (Get-PxList $J::Get($status, 'remote-list'))) {
        $types[$J::Tpl($r['name'])] = $(if ($J::Truthy($r['ty'])) { $r['ty'] } else { $r['type'] })
    }
    $res = Get-PxList $P.resources
    $remotes = New-Object 'System.Collections.Generic.List[object]'
    foreach ($rem in (Select-PxFirst (Get-PxList $P.pdmRemotes) $script:PxCaps.remotes)) {
        $nodes = 0; $nodesUp = 0; $guests = 0; $running = 0
        foreach ($r in $res) {
            if (-not ($r['remote'] -ceq $rem['name'])) { continue }
            if ($r['type'] -ceq 'node') { $nodes++; if ($r['status'] -ceq 'online') { $nodesUp++ } }
            elseif (($r['type'] -ceq 'qemu' -or $r['type'] -ceq 'lxc') -and -not $J::Truthy($r['template'])) { $guests++; if ($r['status'] -ceq 'running') { $running++ } }
        }
        $type = $types[$J::Tpl($rem['name'])]
        if (-not $J::Truthy($type)) { $type = $(if (@($rem['pbsStores']).Count -gt 0) { 'pbs' } else { 'pve' }) }
        $remotes.Add([ordered]@{
            name = $J::Str($rem['name']); type = $J::Str($type, 10); error = $(if ($J::Truthy($rem['error'])) { $J::Str($rem['error'], 120) } else { $null })
            nodes = [long]$nodes; nodesUp = [long]$nodesUp; guests = [long]$guests; running = [long]$running
        })
    }
    $out['remotes'] = $remotes.ToArray()
    $stores = New-Object 'System.Collections.Generic.List[object]'
    foreach ($rem in (Get-PxList $P.pdmRemotes)) {
        foreach ($d in @($rem['pbsStores'])) {
            if ($null -eq $d) { continue }
            $stores.Add([ordered]@{ store = $J::Str($d['store']); remote = $J::Str($rem['name']); used = $J::Int($d['used']); total = $J::Int($d['total']) })
        }
    }
    $out['datastores'] = Select-PxFirst $stores.ToArray() $script:PxCaps.datastores
    if ($J::Truthy($status)) {
        $q = $J::Get($status, 'qemu'); $l = $J::Get($status, 'lxc'); $cpu = $J::Get($status, 'pve_cpu_stats'); $mem = $J::Get($status, 'pve_memory_stats'); $n = $J::Get($status, 'pve_nodes')
        $or0 = { param($v) if ($null -eq $v -or $v -eq 0) { [long]0 } else { $v } }
        $out['totals'] = [ordered]@{
            remotes = $J::Int($J::Get($status, 'remotes')); failed = (& $or0 $J::Int($J::Get($status, 'failed_remotes')))
            nodesUp = $J::Int($J::Get($n, 'online')); nodesDown = $J::Int($J::Get($n, 'offline'))
            running = [long]((& $or0 $J::Int($J::Get($q, 'running'))) + (& $or0 $J::Int($J::Get($l, 'running'))))
            stopped = [long]((& $or0 $J::Int($J::Get($q, 'stopped'))) + (& $or0 $J::Int($J::Get($l, 'stopped'))))
            cpu = $(if ($J::Truthy($J::Get($cpu, 'max'))) { $J::Frac($J::Div($J::Get($cpu, 'used'), $J::Get($cpu, 'max'))) } else { $null })
            cpus = $J::Int($J::Get($cpu, 'max')); mem = $J::Int($J::Get($mem, 'used')); maxmem = $J::Int($J::Get($mem, 'total'))
        }
    } else { $out['totals'] = $null }
    return $out
}

<# A Backup Server: the server, every datastore with its GC and verify state, every backup group, recent tasks.
   GuestName: a scriptblock that turns a vmid into a guest name from the other connections. #>
function ConvertTo-PxPbsOut($P, [scriptblock]$GuestName) {
    $b = if ($P.pbs) { $P.pbs } else { @{} }
    $s = if ($J::Truthy($b.status)) { $b.status } else { @{} }
    if ($J::Truthy($J::Get($s, 'error'))) { $server = [ordered]@{ error = $J::Str($J::Get($s, 'error'), 60) } }
    else {
        $memory = $J::Get($s, 'memory'); $root = $J::Get($s, 'root')
        $server = [ordered]@{
            cpu = $J::Frac($J::Get($s, 'cpu')); mem = $J::Int($J::Get($memory, 'used')); maxmem = $J::Int($J::Get($memory, 'total'))
            uptime = $J::Int($J::Get($s, 'uptime')); load = $J::Load($J::Get($s, 'loadavg'))
            rootUsed = $J::Int($J::Get($root, 'used')); rootTotal = $J::Int($J::Get($root, 'total'))
            version = $J::Version($J::Get($J::Get($s, 'info'), 'version'))
        }
    }
    $recent = Get-PxList $b.recent
    $running = Get-PxList $b.tasks
    $storeOf = { param($t) ($(if ($J::Truthy($t['worker_id'])) { $J::JsString($t['worker_id']) } else { '' })).Split(':')[0] }
    $datastores = New-Object 'System.Collections.Generic.List[object]'
    foreach ($u in (Select-PxFirst ($J::SortByText((Get-PxList $b.usage), 'store')) $script:PxCaps.datastores)) {
        $store = $J::Tpl($u['store'])
        $gc = $null; $groups = $null   # assigned, not from an if: an empty list must stay a list (it counts as 0 groups)
        if ($b.gc -and $b.gc.ContainsKey($store)) { $gc = $b.gc[$store] }
        if ($b.groups -and $b.groups.Contains($store)) { $groups = $b.groups[$store] }
        $verifyList = New-Object 'System.Collections.Generic.List[object]'
        foreach ($t in $recent) { if (([string]$t['worker_type']) -cmatch '^verif' -and (& $storeOf $t) -ceq $store) { $verifyList.Add($t) } }
        $verify = $null
        if ($verifyList.Count) { $verify = $J::SortDesc($verifyList.ToArray(), 'endtime')[0] }
        $lastBackup = 0.0; $snapshots = 0.0
        $groupList = [object[]]@()
        if ($null -ne $groups) { $groupList = Get-PxList $groups }
        foreach ($g in $groupList) {
            $last = if ($J::Truthy($g['last-backup'])) { $J::NumberOf($g['last-backup']) } else { 0 }
            $lastBackup = [Math]::Max($lastBackup, $last)
            $snapshots += $(if ($J::Truthy($g['backup-count'])) { $J::NumberOf($g['backup-count']) } else { 0 })
        }
        $full = $J::Num($u['estimated-full-date'])
        $runningHere = New-Object 'System.Collections.Generic.List[object]'
        foreach ($t in $running) { if ((& $storeOf $t) -ceq $store -or $t['worker_id'] -ceq $store) { if ($runningHere.Count -lt 8) { $runningHere.Add($J::Str($t['worker_type'], 40)) } } }
        $datastores.Add([ordered]@{
            store = $J::Str($u['store']); used = $J::Int($u['used']); total = $J::Int($u['total']); avail = $J::Int($u['avail'])
            fullAt = $(if ($null -ne $full -and $full -gt 0) { $J::Int($full) } else { $null })
            gc = $(if ($J::Truthy($gc)) { [ordered]@{ state = $J::Str($gc['last-run-state'], 60); at = $J::Int($gc['last-run-endtime']); running = ($J::Truthy($gc['upid']) -and -not $J::Truthy($gc['last-run-endtime'])) } } else { $null })
            verify = $(if ($verify) { [ordered]@{ state = $J::Str($verify['status'], 60); at = $J::Int($verify['endtime']) } } else { $null })
            running = $runningHere.ToArray()
            groups = $(if ($null -ne $groups) { [long]$groupList.Count } else { $null })
            snapshots = $(if ($null -ne $groups) { $J::Int($snapshots) } else { $null })
            lastBackup = $(if ($lastBackup) { $J::Int($lastBackup) } else { $null })
        })
    }
    $all = New-Object 'System.Collections.Generic.List[object]'
    if ($b.groups) {
        foreach ($store in $b.groups.Keys) {
            foreach ($g in (Get-PxList $b.groups[$store])) {
                $type = $J::Str($g['backup-type'], 10); $id = $J::Str($g['backup-id'], 80)
                $all.Add([ordered]@{
                    store = $J::Str($store); type = $type; id = $id; last = $J::Int($g['last-backup']); count = $J::Int($g['backup-count'])
                    name = $(if ($type -ceq 'vm' -or $type -ceq 'ct') { & $GuestName $id } else { $null })
                })
            }
        }
    }
    $groupsOut = Select-PxFirst ($J::SortDesc($all.ToArray(), 'last')) $script:PxCaps.groups
    $tasks = New-Object 'System.Collections.Generic.List[object]'
    foreach ($t in (Select-PxFirst $recent $script:PxCaps.tasks)) { $tasks.Add((ConvertTo-PxTaskOut $t)) }
    [ordered]@{ server = $server; datastores = $datastores.ToArray(); groups = $groupsOut; running = [long]$running.Count; tasks = $tasks.ToArray() }
}

<# One connection as the widget reads it (the plugin's connectionOut()). $Conn: the runtime connection, $P: its poll state
   (or $null before the first poll). Never reads the token ID or secret. #>
function ConvertTo-PxConnectionOut($Conn, $P, [scriptblock]$GuestName = { param($id) $null }) {
    $label = $J::Str($Conn.label, 60)
    $hostName = $J::HostOnly($Conn.host)
    $base = [ordered]@{ key = $Conn.key; kind = $Conn.kind; label = $(if ($label) { $label } else { $Conn.key }); host = $(if ($hostName) { $hostName } else { $null }); configured = [bool]$Conn.configured }
    if (-not $Conn.configured) { return $base }
    if ($null -eq $P) { $P = @{} }
    $has = if ($Conn.kind -eq 'pbs') { $null -ne $P.pbs } else { $null -ne $P.resources }
    $base['ok'] = (-not $P.error) -and $has
    $base['error'] = $(if ($P.error) { $J::Str($P.error, 60) } else { $null })
    $base['updatedAt'] = $(if ($P.updatedAt) { [long]$P.updatedAt } else { $null })
    if (-not $has) { return $base }
    $more = if ($Conn.kind -eq 'pbs') { ConvertTo-PxPbsOut $P $GuestName } elseif ($Conn.kind -eq 'pdm') { ConvertTo-PxPdmOut $P } else { ConvertTo-PxPveOut $P $false }
    foreach ($k in $more.Keys) { $base[$k] = $more[$k] }
    return $base
}

<# The whole file, minus seq and at. #>
function New-PxStateBody([object[]]$Connections, [int]$Interval, [bool]$Ready = $true, [bool]$Running = $true) {
    $list = $Connections
    if ($null -eq $list) { $list = [object[]]@() }
    $body = [ordered]@{
        app = $script:PxApp; schema = $script:PxSchema; writer = 'companion'; writerVersion = $script:PxVersion
        enabled = $true; running = $Running; interval = $Interval; connections = $list
    }
    $body['ready'] = $Ready
    return $body
}

<# seq and at after the body, then "end": true last, so a read cut short never parses as whole. #>
function ConvertTo-PxStateText($Body, [long]$Seq, [long]$At) {
    $o = [ordered]@{}
    foreach ($k in $Body.Keys) { $o[$k] = $Body[$k] }
    $o['seq'] = $Seq; $o['at'] = $At
    $json = [ProxmoxLink.Json]::Stringify($o)
    return $json.Substring(0, $json.Length - 1) + ',"end":true}'
}

# ---------------------------------------------------------------------------------------------------------------------
# Writing files that iCUE holds open
# ---------------------------------------------------------------------------------------------------------------------
<# Writes a file whole: a temp file moved over it; iCUE holds state.json open without delete sharing for a moment after
   each change, which refuses the move, so after one retry 5 ms later it is rewritten in place (opened with read, write
   and delete sharing, which a held file allows). Returns renamed, in place, held or failed; never throws. #>
function Write-PxFileWhole([string]$Dir, [string]$Name, [string]$Text) {
    $path = Join-Path $Dir $Name
    $tmp = "$path.tmp"
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Text)
    try {
        [void][IO.Directory]::CreateDirectory($Dir)
        [IO.File]::WriteAllBytes($tmp, $bytes)
    } catch { return 'failed' }
    try {
        for ($attempt = 0; $attempt -lt 2; $attempt++) {
            try {
                if ([IO.File]::Exists($path)) { [IO.File]::Replace($tmp, $path, [NullString]::Value) } else { [IO.File]::Move($tmp, $path) }
                return 'renamed'
            } catch { if ($attempt -eq 0) { Start-Sleep -Milliseconds 5 } }
        }
        try {
            $fs = New-Object IO.FileStream($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try { $fs.Write($bytes, 0, $bytes.Length); $fs.SetLength($bytes.Length); $fs.Flush() } finally { $fs.Dispose() }
            return 'in place'
        } catch { return 'held' }
    } finally {
        try { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } } catch { }
    }
}

<# The heartbeat the plugin looks for: {"at": <ms>} in companion.json; while it is under 5 s old the plugin leaves
   state.json alone. #>
function Write-PxHeartbeat([string]$Dir) {
    return Write-PxFileWhole -Dir $Dir -Name 'companion.json' -Text ('{"at":' + $J::Now() + '}')
}

# ---------------------------------------------------------------------------------------------------------------------
# The poller: one loop per connection (each in its own runspace, so a slow server never holds up another), and a
# supervisor that owns the settings, the heartbeat and the state file
# ---------------------------------------------------------------------------------------------------------------------
<# Polls one connection until $Stop is set: every interval, after a failure 2, 4, 8, then 12 intervals until it answers;
   the Proxmox VE extras when they are due. Each result is published to $Slot.Snapshot as a fresh hashtable. #>
function Start-PxConnectionLoop($Conn, [int]$Interval, $Shared, $Slot, [Threading.WaitHandle]$Stop) {
    [ProxmoxLink.Log]::AddSecret($Conn.secret)
    $state = @{ resources = $null; pbs = $null; pdmStatus = $null; pdmRemotes = $null; extras = $null; error = $null; failures = 0; updatedAt = 0; lastAttempt = 0 }
    $seq = 0
    while (-not $Stop.WaitOne(0)) {
        try {
            if ($Shared.Paused) { $state.lastAttempt = 0; [void]$Stop.WaitOne(500); continue }
            $now = $J::Now()
            $wait = $Interval * 1000 * [Math]::Min(12, [Math]::Pow(2, [Math]::Min(4, $state.failures)))
            $changed = $false
            if ($now - $state.lastAttempt -ge $wait) {
                $state.lastAttempt = $now
                $wasError = $state.error
                Invoke-PxPoll $Conn $state $Interval
                if ($state.error -and $state.error -ne $wasError) { Write-PxLog 'warn' "connection $($Conn.key) ($($Conn.host)): $($state.error)" }
                elseif (-not $state.error -and $wasError) { Write-PxLog 'info' "connection $($Conn.key) ($($Conn.host)) answers again" }
                $changed = $true
            }
            if (Invoke-PxPollExtras $Conn $state) { $changed = $true }
            if ($changed) {
                $seq++
                $Slot.Snapshot = @{
                    resources = $state.resources; pbs = $state.pbs; pdmStatus = $state.pdmStatus; pdmRemotes = $state.pdmRemotes
                    extras = $state.extras; error = $state.error; updatedAt = $state.updatedAt; failures = $state.failures; seq = $seq
                }
            }
        } catch { Write-PxLog 'error' "connection $($Conn.key) loop: $($_.Exception.Message)" }
        [void]$Stop.WaitOne(250)
    }
}

function Start-PxGeneration($Config, $Shared) {
    $gen = @{
        Interval = [int]$Config.interval
        Conns = [ordered]@{}
        Slots = @{}
        Stop = New-Object Threading.ManualResetEvent($false)
        Workers = New-Object 'System.Collections.Generic.List[object]'
    }
    foreach ($c in $Config.connections) {
        $rc = Get-PxRuntimeConnection $c
        if ($c.secret -and -not $rc.secret) { Write-PxLog 'warn' "connection $($c.key): the saved secret cannot be read on this account; enter it again in setup" }
        $gen.Conns[$rc.key] = $rc
        $gen.Slots[$rc.key] = [hashtable]::Synchronized(@{ Snapshot = $null })
        if (-not $rc.configured) { continue }
        if (-not $rc.pin -and -not $rc.trustWindows) { Write-PxLog 'warn' "connection $($rc.key): no trusted certificate yet; press Test in setup and trust it" }
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript('param($core, $conn, $interval, $shared, $slot, $stop) . $core; Start-PxConnectionLoop -Conn $conn -Interval $interval -Shared $shared -Slot $slot -Stop $stop')
        [void]$ps.AddArgument($Shared.CorePath).AddArgument($rc).AddArgument($gen.Interval).AddArgument($Shared).AddArgument($gen.Slots[$rc.key]).AddArgument($gen.Stop)
        $gen.Workers.Add(@{ ps = $ps; rs = $rs; handle = $ps.BeginInvoke() })
        Write-PxLog 'info' "connection $($rc.key): $($script:PxKindName[$rc.kind]) at $($rc.host):$($rc.port), every $($gen.Interval) s"
    }
    return $gen
}

<# Tells a generation's loops to stop; they finish their current request (8 s at most) in the background. #>
function Stop-PxGeneration($Gen, $Draining) {
    if ($null -eq $Gen) { return }
    [void]$Gen.Stop.Set()
    foreach ($w in $Gen.Workers) { $Draining.Add($w) }
}

function Clear-PxDrained($Draining) {
    foreach ($w in $Draining.ToArray()) {
        if ($w.handle.IsCompleted) {
            try { [void]$w.ps.EndInvoke($w.handle) } catch { }
            $w.ps.Dispose(); $w.rs.Dispose()
            [void]$Draining.Remove($w)
        }
    }
}

<# The state file's body from every connection's latest poll (a backup group's guest name from the Proxmox VE and
   Datacenter Manager connections, in A, B, C order, as the plugin finds it). #>
function Get-PxGenerationBody($Gen) {
    $names = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
    foreach ($k in $script:PxKeys) {
        $c = $Gen.Conns[$k]
        if ($null -eq $c -or $c.kind -eq 'pbs') { continue }
        $snap = $Gen.Slots[$k].Snapshot
        if ($null -eq $snap) { continue }
        foreach ($r in (Get-PxList $snap.resources)) {
            if ($r['type'] -ceq 'qemu' -or $r['type'] -ceq 'lxc') {
                $id = $J::JsString($r['vmid'])
                if (-not $names.ContainsKey($id)) { $names[$id] = $r['name'] }
            }
        }
    }
    $guestName = { param($id) if ($null -ne $id -and $names.ContainsKey([string]$id)) { $names[[string]$id] } else { $null } }.GetNewClosure()
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($k in $script:PxKeys) {
        $c = $Gen.Conns[$k]
        try { $list.Add((ConvertTo-PxConnectionOut $c $Gen.Slots[$k].Snapshot $guestName)) }
        catch {
            Write-PxLog 'error' "connection $k could not be shaped: $($_.Exception.Message)"
            $list.Add([ordered]@{ key = $c.key; kind = $c.kind; label = $(if ($c.label) { $c.label } else { $c.key }); host = $(if ($J::HostOnly($c.host)) { $J::HostOnly($c.host) } else { $null }); configured = [bool]$c.configured; ok = $false; error = 'Bad data'; updatedAt = $null })
        }
    }
    return New-PxStateBody -Connections $list.ToArray() -Interval $Gen.Interval
}

<# What the tray shows: a light and a short line (a tray tooltip holds 63 characters). #>
function Get-PxStatus($Body) {
    $set = @($Body.connections | Where-Object { $_['configured'] })
    if (-not $set.Count) { return @{ Light = 'grey'; Text = 'Proxmox Link: nothing set up yet' } }
    $bad = @($set | Where-Object { -not $_['ok'] })
    if (-not $bad.Count) { return @{ Light = 'green'; Text = "Proxmox Link: $(Get-PxPlural $set.Count 'connection') OK" } }
    $first = $bad[0]
    $why = if ($first['error']) { $first['error'] } else { 'waiting' }
    $text = if ($bad.Count -eq 1) { "Proxmox Link: $($first['key']) $why" } else { "Proxmox Link: $($bad.Count) of $($set.Count) failing" }
    $light = if ($bad.Count -eq $set.Count -and $first['error']) { 'red' } else { 'amber' }
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
    return @{ Light = $light; Text = $text }
}

<# The supervisor: settings (re-read when config.json changes), the connection loops, the heartbeat every 2 s and the
   state file (on a change at most once a second, and every 5 s regardless, as the plugin paces it). Ends when
   $Shared.Stop is set or the quit event is signalled, with one last file saying running: false. #>
function Invoke-PxSupervisor($Shared) {
    $paths = Get-PxPaths
    $draining = New-Object 'System.Collections.Generic.List[object]'
    $w = @{ seq = [long]0; last = [long]0; lastBody = ''; lastHow = $null; held = 0 }
    $writeState = {
        param($Body, [bool]$Force)
        $now = $J::Now()
        $text = [ProxmoxLink.Json]::Stringify($Body)
        $changed = $text -ne $w.lastBody
        if (-not $Force -and -not ($changed -and ($now - $w.last) -ge 1000) -and ($now - $w.last) -lt 5000) { return }
        $w.seq++
        $how = Write-PxFileWhole -Dir $paths.StateDir -Name 'state.json' -Text (ConvertTo-PxStateText $Body $w.seq $now)
        $w.last = $now; $w.lastBody = $text
        if ($how -ne $w.lastHow) { Write-PxLog $(if ($how -eq 'held' -or $how -eq 'failed') { 'warn' } else { 'info' }) "state file: $how"; $w.lastHow = $how }
    }
    $gen = $null; $stamp = $null; $lastCheck = [long]0; $lastBeat = [long]0; $paused = $false
    $body = $null; $bodyKey = $null
    $config = Read-PxConfig $paths.ConfigFile
    Write-PxLog 'info' "Proxmox Link $script:PxVersion started (PowerShell $($PSVersionTable.PSVersion), pid $PID)"
    try {
        [void][IO.Directory]::CreateDirectory($paths.StateDir)
        [void](Write-PxHeartbeat $paths.StateDir); $lastBeat = $J::Now()
        & $writeState (New-PxStateBody -Connections @() -Interval $config.interval -Ready $false) $true
        while (-not $Shared.Stop) {
            if ($Shared.QuitEvent -and $Shared.QuitEvent.WaitOne(0)) { Write-PxLog 'info' 'asked to quit'; break }
            $now = $J::Now()
            if ($now - $lastCheck -ge 3000) {
                $lastCheck = $now
                $fi = New-Object IO.FileInfo($paths.ConfigFile)
                $newStamp = if ($fi.Exists) { "$($fi.LastWriteTimeUtc.Ticks)/$($fi.Length)" } else { 'none' }
                if ($newStamp -ne $stamp) {
                    if ($null -ne $stamp) { Write-PxLog 'info' 'settings changed: restarting the connections' }
                    $stamp = $newStamp
                    $config = Read-PxConfig $paths.ConfigFile
                    Stop-PxGeneration $gen $draining
                    $gen = Start-PxGeneration $config $Shared
                    $bodyKey = $null
                }
                Clear-PxDrained $draining
            }
            if ($Shared.Paused) {
                if (-not $paused) {
                    $paused = $true
                    Write-PxLog 'info' 'paused'
                    if ($body) { $b = [ordered]@{}; foreach ($k in $body.Keys) { $b[$k] = $body[$k] }; $b['running'] = $false; & $writeState $b $true }
                    try { [IO.File]::Delete($paths.CompanionFile) } catch { }
                    $Shared.Light = 'grey'; $Shared.Text = 'Proxmox Link: paused'
                }
                [void]$Shared.StopEvent.WaitOne(250)
                continue
            }
            if ($paused) { $paused = $false; $bodyKey = $null; $lastBeat = 0; Write-PxLog 'info' 'resumed' }
            if ($now - $lastBeat -ge 2000) { [void](Write-PxHeartbeat $paths.StateDir); $lastBeat = $now }
            $key = ($script:PxKeys | ForEach-Object { $s = $gen.Slots[$_].Snapshot; if ($s) { $s.seq } else { 0 } }) -join ','
            if ($key -ne $bodyKey) {
                $body = Get-PxGenerationBody $gen
                $bodyKey = $key
                $st = Get-PxStatus $body
                $Shared.Light = $st.Light; $Shared.Text = $st.Text
            }
            & $writeState $body $false
            [void]$Shared.StopEvent.WaitOne(250)
        }
    } catch {
        Write-PxLog 'error' "supervisor: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
        throw
    } finally {
        Stop-PxGeneration $gen $draining
        if ($body -and -not $paused) {
            $b = [ordered]@{}; foreach ($k in $body.Keys) { $b[$k] = $body[$k] }; $b['running'] = $false
            & $writeState $b $true
        }
        try { [IO.File]::Delete($paths.CompanionFile) } catch { }
        Write-PxLog 'info' 'Proxmox Link stopped'
        $Shared.Done = $true
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Setup's Test: the certificate first, then one poll, then counts
# ---------------------------------------------------------------------------------------------------------------------
function Get-PxProbePath([string]$Kind) {
    switch ($Kind) { 'pbs' { '/status/datastore-usage' } 'pdm' { '/resources/status?max-age=30' } default { '/cluster/resources' } }
}

<# Returns @{ ok; cert = pinned|windows|new|changed|none; fingerprint; subject; issuer; notAfter; error; summary }. The
   token is only sent once the certificate is accepted: a refused certificate ends the handshake first. #>
function Test-PxConnection($Conn) {
    $res = @{ ok = $false; cert = 'none'; fingerprint = $null; subject = $null; issuer = $null; notAfter = $null; error = $null; summary = $null; windows = $false }
    if (-not $Conn.host) { $res.error = 'Enter the host name.'; return $res }
    if (-not $Conn.tokenId) { $res.error = 'Enter the API token ID.'; return $res }
    if (-not $Conn.secret) { $res.error = 'Enter the token secret.'; return $res }
    $r = [ProxmoxLink.Http]::Get($Conn.host, $Conn.port, (Get-PxProbePath $Conn.kind), (Get-PxAuthHeader $Conn), $Conn.pin, $Conn.trustWindows, 8000, $true)
    $res.fingerprint = $r.Fingerprint; $res.subject = $r.Subject; $res.issuer = $r.Issuer; $res.notAfter = $r.NotAfter; $res.windows = $r.CertTrustedByWindows
    if ($r.CertSeen -and -not $r.CertAccepted) {
        $res.cert = if ($Conn.pin) { 'changed' } else { 'new' }
        $res.error = 'TLS cert'
        return $res
    }
    if ($r.CertSeen) { $res.cert = if ($Conn.pin -and [ProxmoxLink.Http]::NormalizePin($r.Fingerprint) -eq [ProxmoxLink.Http]::NormalizePin($Conn.pin)) { 'pinned' } else { 'windows' } }
    if ($r.Error) { $res.error = Get-PxFriendlyError $r.Error; $res.detail = $r.Error; return $res }
    $state = @{ resources = $null; pbs = $null; pdmStatus = $null; pdmRemotes = $null; extras = $null; error = $null; failures = 0; updatedAt = 0 }
    Invoke-PxPoll $Conn $state 30
    if ($state.error) { $res.error = $state.error; return $res }
    if ($Conn.kind -eq 'pve') { [void](Invoke-PxPollExtras $Conn $state) }
    $out = ConvertTo-PxConnectionOut $Conn $state
    $res.ok = $true
    $res.summary = Get-PxSummary $out
    return $res
}

function Get-PxPlural([long]$N, [string]$One, [string]$Many = "$($One)s") { if ($N -eq 1) { "1 $One" } else { "$N $Many" } }

<# "3 nodes (3 online), 24 guests (18 running), 5 storages" and so on, from a connection as the file has it. #>
function Get-PxSummary($Out) {
    $parts = @()
    if ($Out.kind -eq 'pbs') {
        $ds = @($Out.datastores); $groups = @($Out.groups)
        $parts += Get-PxPlural $ds.Count 'datastore'
        $parts += Get-PxPlural $groups.Count 'backup group'
        if ($Out.server -and $Out.server['version']) { $parts += "Backup Server $($Out.server['version'])" }
        elseif ($Out.server -and $Out.server['error']) { $parts += "server status: $($Out.server['error'])" }
    } else {
        $nodes = @($Out.nodes); $guests = @($Out.guests); $stor = @($Out.storages)
        if ($Out.kind -eq 'pdm') { $parts += Get-PxPlural @($Out.remotes).Count 'remote' }
        $parts += (Get-PxPlural $nodes.Count 'node') + " ($(@($nodes | Where-Object { $_['status'] -eq 'online' }).Count) online)"
        $parts += (Get-PxPlural $guests.Count 'guest') + " ($(@($guests | Where-Object { $_['status'] -eq 'running' }).Count) running)"
        $parts += Get-PxPlural $stor.Count 'storage'
        if ($Out.kind -eq 'pve' -and $Out.cluster) { $parts += "cluster $($Out.cluster['name'])" }
        $v = @($nodes | Where-Object { $_['version'] } | Select-Object -First 1)
        if ($v.Count) { $parts += "Proxmox VE $($v[0]['version'])" }
    }
    return ($parts -join ', ')
}

# ---------------------------------------------------------------------------------------------------------------------
# The icon (drawn here: three server rows and a status light; no Proxmox artwork)
# ---------------------------------------------------------------------------------------------------------------------
function New-PxIconBitmap([int]$Size, [string]$Light = '#3fb950') {
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object Drawing.Bitmap($Size, $Size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([Drawing.Color]::Transparent)
        $u = $Size / 32.0
        $path = New-Object Drawing.Drawing2D.GraphicsPath
        $r = 7 * $u; $w = $Size - 1
        $path.AddArc(0, 0, $r * 2, $r * 2, 180, 90); $path.AddArc($w - $r * 2, 0, $r * 2, $r * 2, 270, 90)
        $path.AddArc($w - $r * 2, $w - $r * 2, $r * 2, $r * 2, 0, 90); $path.AddArc(0, $w - $r * 2, $r * 2, $r * 2, 90, 90); $path.CloseFigure()
        $g.FillPath((New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml('#141a21'))), $path)
        $rowBrush = New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml('#c9d1d9'))
        $ledBrush = New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml('#e57000'))
        foreach ($i in 0..2) {
            $y = (6 + $i * 7) * $u
            $g.FillRectangle($rowBrush, [single](5 * $u), [single]$y, [single](22 * $u), [single](5 * $u))
            $g.FillRectangle($ledBrush, [single](7 * $u), [single]($y + 1.5 * $u), [single](2 * $u), [single](2 * $u))
        }
        $d = 11 * $u
        $g.FillEllipse((New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml('#141a21'))), [single]($Size - $d - 0.5 * $u), [single]($Size - $d - 0.5 * $u), [single]$d, [single]$d)
        $d2 = 8 * $u
        $g.FillEllipse((New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml($Light))), [single]($Size - $d2 - 2 * $u), [single]($Size - $d2 - 2 * $u), [single]$d2, [single]$d2)
    } finally { $g.Dispose() }
    return $bmp
}

<# An .ico file with PNG images at 16, 32, 48 and 256 px, for the shortcuts. #>
function Save-PxIconFile([string]$Path) {
    $sizes = 16, 32, 48, 256
    $pngs = foreach ($s in $sizes) {
        $bmp = New-PxIconBitmap $s
        $ms = New-Object IO.MemoryStream
        try { $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); , $ms.ToArray() } finally { $bmp.Dispose(); $ms.Dispose() }
    }
    $out = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter($out)
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $s = $sizes[$i]; $b = if ($s -ge 256) { 0 } else { $s }
        $w.Write([byte]$b); $w.Write([byte]$b); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
        $offset += $pngs[$i].Length
    }
    foreach ($p in $pngs) { $w.Write([byte[]]$p) }
    $w.Flush()
    [IO.File]::WriteAllBytes($Path, $out.ToArray())
    $w.Dispose()
}

# ---------------------------------------------------------------------------------------------------------------------
# Start at sign-in, start and stop
# ---------------------------------------------------------------------------------------------------------------------
function Get-PxStartupShortcutPath([string]$StartupDir = [Environment]::GetFolderPath('Startup')) { Join-Path $StartupDir 'Proxmox Link.lnk' }

<# The command line every launch uses: Windows blocks unsigned scripts by default, so -ExecutionPolicy Bypass for this one
   run (the machine and user policies are never changed). #>
function Get-PxLaunchArguments([string]$Script) { "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Script`"" }

function Get-PxPowerShellExe { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }

function New-PxShortcut([string]$Path, [string]$Target, [string]$Arguments, [string]$WorkingDir, [string]$Icon, [string]$Description, [int]$WindowStyle = 7) {
    $shell = New-Object -ComObject WScript.Shell
    try {
        $lnk = $shell.CreateShortcut($Path)
        $lnk.TargetPath = $Target
        $lnk.Arguments = $Arguments
        $lnk.WorkingDirectory = $WorkingDir
        if ($Icon -and (Test-Path -LiteralPath $Icon)) { $lnk.IconLocation = "$Icon,0" }
        $lnk.Description = $Description
        $lnk.WindowStyle = $WindowStyle
        $lnk.Save()
    } finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
}

function Set-PxStartAtSignIn([bool]$On, [string]$LinkScript, [string]$StartupDir = [Environment]::GetFolderPath('Startup')) {
    $lnk = Get-PxStartupShortcutPath $StartupDir
    if ($On) {
        $dir = Split-Path -Parent $LinkScript
        New-PxShortcut -Path $lnk -Target (Get-PxPowerShellExe) -Arguments (Get-PxLaunchArguments $LinkScript) -WorkingDir $dir -Icon (Join-Path $dir 'ProxmoxLink.ico') -Description 'Proxmox Link: feeds the Proxmox Dashboard widget'
    } elseif (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
}

<# Hides the console window, but only when it is this script's own (started from a shortcut), never a terminal the user
   ran the script in. #>
function Hide-PxOwnConsole {
    try {
        if (-not ('ProxmoxLink.Console' -as [type])) {
            Add-Type -Namespace ProxmoxLink -Name Console -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("kernel32.dll")] public static extern uint GetConsoleProcessList(uint[] list, uint count);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
'@
        }
        $list = New-Object 'uint32[]' 8
        $n = [ProxmoxLink.Console]::GetConsoleProcessList($list, 8)
        $h = [ProxmoxLink.Console]::GetConsoleWindow()
        if ($h -ne [IntPtr]::Zero -and $n -le 1) { [void][ProxmoxLink.Console]::ShowWindow($h, 0) }
    } catch { }
}

<# What a typed host means: "https://pve01.home.arpa:8006/" gives host pve01.home.arpa and port 8006. #>
function Split-PxHostInput([string]$Text) {
    $t = ([string]$Text).Trim()
    if (-not $t) { return @{ host = ''; port = $null } }
    if (($t.Split(':').Count -gt 2) -and -not $t.Contains('[') -and -not $t.Contains('://')) { return @{ host = $t; port = $null } }   # a bare IPv6 address
    $u = $null
    $withScheme = if ($t -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $t } else { "https://$t" }
    if ([Uri]::TryCreate($withScheme, [UriKind]::Absolute, [ref]$u) -and $u.Host) {
        $explicit = $withScheme -match '^[^/]*//(?:[^@/]*@)?(?:\[[^\]]*\]|[^:/]*):(\d+)'
        return @{ host = $J::HostOnly($t); port = $(if ($explicit) { [int]$Matches[1] } else { $null }) }
    }
    return @{ host = $t; port = $null }
}

function Test-PxRunning {
    $m = $null
    if ([Threading.Mutex]::TryOpenExisting((Get-PxPaths).MutexName, [ref]$m)) { $m.Dispose(); return $true }
    return $false
}

function Start-PxLink([string]$LinkScript) {
    Start-Process -FilePath (Get-PxPowerShellExe) -ArgumentList (Get-PxLaunchArguments $LinkScript) -WindowStyle Hidden -WorkingDirectory (Split-Path -Parent $LinkScript)
}

<# Asks a running Proxmox Link to quit (it writes running: false and removes its heartbeat). True once it has gone. #>
function Stop-PxLink([int]$WaitMs = 10000) {
    $p = Get-PxPaths
    $e = $null
    if ([Threading.EventWaitHandle]::TryOpenExisting($p.QuitEventName, [ref]$e)) { [void]$e.Set(); $e.Dispose() }
    $t0 = [datetime]::UtcNow
    while (([datetime]::UtcNow - $t0).TotalMilliseconds -lt $WaitMs) { if (-not (Test-PxRunning)) { return $true }; Start-Sleep -Milliseconds 200 }
    return -not (Test-PxRunning)
}
