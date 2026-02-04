# -include .env
# Makefile

RPC_URL := "https://1rpc.io/sepolia"
KEYSTORE := ~/.foundry/keystores/default
SENDER   := 0xf43f4fc18bacefe1c96e4fa6bdc8585fbaed4cf7
SCRIPT   := script/Deploy.s.sol:Deploy
ETHERSCAN_API_KEY := PJFEDANUFHK7RWQXU52P67QXJTVM4HB9IU


.PHONY: deploy

deploy:
	forge script $(SCRIPT) \
	  --rpc-url $(RPC_URL) \
	  --keystore $(KEYSTORE) \
	  --password "meow" \
	  --sender $(SENDER) \
	  --broadcast \
	  --verify \
	  --etherscan-api-key $(ETHERSCAN_API_KEY) \
	  -vvvv
