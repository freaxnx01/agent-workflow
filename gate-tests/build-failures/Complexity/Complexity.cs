namespace GateFixtures;

/// <summary>Fixture that trips CA1502 (excessive cyclomatic complexity).</summary>
public static class Complexity
{
    /// <summary>
    /// Cyclomatic complexity ~13 (twelve independent branches), well above the
    /// CA1502 threshold of 10 configured in ../CodeMetricsConfig.txt.
    /// </summary>
    public static int Evaluate(int n)
    {
        int r = 0;
        if (n == 1) { r++; }
        if (n == 2) { r++; }
        if (n == 3) { r++; }
        if (n == 4) { r++; }
        if (n == 5) { r++; }
        if (n == 6) { r++; }
        if (n == 7) { r++; }
        if (n == 8) { r++; }
        if (n == 9) { r++; }
        if (n == 10) { r++; }
        if (n == 11) { r++; }
        if (n == 12) { r++; }
        return r;
    }
}
