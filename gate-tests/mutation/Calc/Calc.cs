namespace GateFixtures;

/// <summary>Real production logic with plenty of mutable operators.</summary>
public static class Calc
{
    /// <summary>Adds two integers.</summary>
    public static int Add(int a, int b) => a + b;

    /// <summary>Returns true when the value is strictly positive.</summary>
    public static bool IsPositive(int value) => value > 0;

    /// <summary>Clamps <paramref name="value"/> into [low, high].</summary>
    public static int Clamp(int value, int low, int high)
    {
        if (value < low) { return low; }
        if (value > high) { return high; }
        return value;
    }
}
