import Test.HUnit

import SecondTransfer.Test.DecoySession

import Tests.HTTP2Session


test1 = TestCase (assertEqual "for (foo 3)," (1,2) (1,2))
test2 = TestCase (
	do 
		(x,y) <- return (1,2)
		assertEqual "for the first result of partA," 5 5
		b <- return True
		assertBool ( "(partB" ++ show y ++ ") failed" ) b
	)

tests = TestList [
	TestLabel "testPrefaceChecks" testPrefaceChecks,
	TestLabel "testPrefaceChecks2" testPrefaceChecks2
	]


main = do 
	runTestTT tests 
	return ()