using Xunit;

namespace GateFixtures.Tests;

public class CalcTests
{
    // Deliberately weak: it exercises the code so the mutants are COVERED, but
    // asserts nothing meaningful, so every mutant SURVIVES. Mutation score -> 0%,
    // which is below the Stryker break threshold of 60, so Stryker exits non-zero.
    [Fact]
    public void ExercisesButAssertsNothing()
    {
        _ = Calc.Add(2, 3);
        _ = Calc.IsPositive(5);
        _ = Calc.Clamp(7, 0, 10);
        Assert.True(true);
    }
}
