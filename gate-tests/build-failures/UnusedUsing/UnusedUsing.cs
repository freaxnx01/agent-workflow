using System;
using System.Text; // <- unused: trips IDE0005

namespace GateFixtures;

/// <summary>Fixture that trips IDE0005 (unnecessary using directive).</summary>
public static class UnusedUsing
{
    /// <summary>Uses System (DateTime) only; System.Text is dead weight.</summary>
    public static string Now() => DateTime.UtcNow.ToString("O");
}
