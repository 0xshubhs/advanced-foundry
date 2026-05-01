### S-# Looping though finding of DUpliocated in PuppyRaffle 
`PuppyRaffle:enterRaffle is a potential POC for Denial of Service. 




Description : The function enterRaffle allows function loops thorigh the `players` arreat to check for the duplicates . Howeever the longer tghe `PuppyRaffle :: platyersa ` array the more gas it will cost to execute the function. An attacker can exploit this by entering the raffle multiple times with different addresses, which will increase the size of the `players` array and make it more expensive for other users to enter the raffle or even cause transactions to fail due to exceeding gas limits. FORNTERUNNING

## IMPACT : the gas coistrs for raffle entarbts will greatly incerese as ore player etner the raffle, potentially leading to a denial of service for users trying to enter the raffle.

An attacker might make th `PupoyRaffle::entrabts ` array so big, that no one else enters guyranteeing themselcves a win in the raffle.


**proof of concept **   :
```solidity
// SPDX-License-Identifier: MIT
   function runthrough() public {
        uint256 times = 200;
    
        address[] memory DosPlayers = new address[](times);
        for (uint256 i = 0; i < times; i++) {
            DosPlayers[i] = address(i);
            }
        uint256 gasStart = gasleft();
        puppyRaffle.enterRaffle{value: entranceFee*DosPlayers.length}(DosPlayers);
        uint256 gasENd = gasleft();

        uint256 gasUsed = (gasStart - gasENd);
        console.log("Gas Used:", gasUsed);

    }
```


RECOMMENEDED Mitigation : There are a few recommendations to mitigate this issue: 

1> Consider allowing Duplicates: 

2> Consider using a mapping to check for the duplicates instead of looping through the array. This would allow for constant time complexity when checking for duplicates, regardless of the size of the `players` array.
```solidity
mapping(address => bool) private hasEntered;
```


IMPACT : MEDIUM / HIGH 
LIKELIHOOD : MEDIUM 



