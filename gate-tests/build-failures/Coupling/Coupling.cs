using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace GateFixtures;

/// <summary>Fixture that trips CA1506 (excessive class coupling).</summary>
public static class Coupling
{
    /// <summary>
    /// Actually uses 25+ distinct types in a single member, exceeding the
    /// CA1506 threshold of 20 configured in ../CodeMetricsConfig.txt. Every
    /// imported namespace is used, so IDE0005 stays silent and CA1506 is the
    /// sole error. (typeof() references alone do not count toward coupling.)
    /// </summary>
    public static int Touch()
    {
        var sb = new StringBuilder();
        var list = new List<int>();
        var dict = new Dictionary<string, int>();
        var dt = new DateTime(2020, 1, 1);
        var ts = new TimeSpan(1, 0, 0);
        var guid = Guid.NewGuid();
        var uri = new Uri("https://example.com");
        var ver = new Version(1, 2);
        var rnd = new Random(1);
        var dto = new DateTimeOffset(dt, ts);
        var ci = CultureInfo.InvariantCulture;
        var enc = Encoding.UTF8;
        var ms = new MemoryStream();
        var writer = new StringWriter();
        var reader = new StringReader("x");
        var dec = new decimal(1);
        var bytes = BitConverter.GetBytes(1);
        var b64 = Convert.ToBase64String(bytes);
        var max = Math.Max(1, 2);
        var lazy = new Lazy<int>(() => 1);
        var comparer = StringComparer.Ordinal;
        var tz = TimeZoneInfo.Utc;
        var error = new InvalidOperationException();
        var queue = new Queue<int>();
        var stack = new Stack<int>();
        var set = new HashSet<int>();

        return sb.Length + list.Count + dict.Count + dt.Day + ts.Hours
            + guid.GetHashCode() + uri.Port + ver.Major + rnd.Next()
            + dto.Day + ci.LCID + enc.CodePage + (int)ms.Length
            + writer.ToString().Length + reader.Read() + (int)dec + bytes.Length
            + b64.Length + max + lazy.Value + comparer.GetHashCode()
            + tz.BaseUtcOffset.Hours + error.Message.Length + queue.Count
            + stack.Count + set.Count;
    }
}
