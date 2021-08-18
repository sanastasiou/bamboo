﻿// BAMWallet by Matthew Hellyer is licensed under CC BY-NC-ND 4.0.
// To view a copy of this license, visit https://creativecommons.org/licenses/by-nc-nd/4.0

using System.Collections.Generic;
using System.Linq;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using BAMWallet.Extensions;
using BAMWallet.HD;
using BAMWallet.Helper;
using BAMWallet.Model;
using Dawn;
using MessagePack;
using NBitcoin;
namespace BAMWallet.Rpc.Controllers
{
    [Route("api/wallet")]
    [ApiController]
    public class WalletController
    {
        private readonly IWalletService _walletService;

        private IActionResult GetHistory(Credentials credentials, bool last = false)
        {
            Guard.Argument(credentials, nameof(credentials)).NotNull();
            var session = new Session(credentials.Identifier.ToSecureString(), credentials.Passphrase.ToSecureString());
            var history = _walletService.History(session);
            if (history.Item1 is null)
            {
                return new BadRequestObjectResult(history.Item2);
            }
            var balance = (history.Item1 as IOrderedEnumerable<BalanceSheet>);
            return last ? new OkObjectResult($"{balance.Last()}") : new OkObjectResult(balance);
        }

        public WalletController(IWalletService walletService)
        {
            _walletService = walletService;
        }

        [HttpPost("address", Name = "Address")]
        public IActionResult Address([FromBody] Credentials credentials)
        {
            Guard.Argument(credentials, nameof(credentials)).NotNull();

            using var identifier = credentials.Identifier.ToSecureString();
            using var pass = credentials.Passphrase.ToSecureString();

            if(Session.AreCredentialsValid(identifier, pass))
            {
                var session = new Session(identifier, pass);
                var result = _walletService.Address(session);
                if (result.Item1 is null)
                {
                    return new BadRequestObjectResult(result.Item2);
                }
                var address = (result.Item1 as string);
                return new OkObjectResult(address);
            }
            return new BadRequestObjectResult("Invalid identifier or password!");
        }

        [HttpPost("balance", Name = "Balance")]
        public IActionResult Balance([FromBody] Credentials credentials)
        {
            return GetHistory(credentials, true);
        }

        [HttpGet("create", Name = "Create")]
        public IActionResult Create(string seed = null, string passphrase = null)
        {
            string[] seedDefault = _walletService.CreateSeed(Language.English, WordCount.TwentyFour);
            string[] passPhraseDefault = _walletService.CreateSeed(Language.English, WordCount.Twelve);
            string joinMmnemonic = string.Join(" ", seed ?? string.Join(' ', seedDefault));
            string joinPassphrase = string.Join(" ", passphrase ?? string.Join(' ', passPhraseDefault));
            string id = _walletService.CreateWallet(joinMmnemonic.ToSecureString(), joinPassphrase.ToSecureString());
            var session = new Session(id.ToSecureString(), joinPassphrase.ToSecureString());

            var addressResult = _walletService.Address(session);
            if (addressResult.Item1 is null)
            {
                return new BadRequestObjectResult(addressResult.Item2 as string);
            }

            return new OkObjectResult(new
            {
                path = Util.WalletPath(id),
                identifier = id,
                seed = joinMmnemonic,
                passphrase = joinPassphrase,
                address = addressResult.Item1 as string
            });
        }

        [HttpGet("seed", Name = "CreateSeed")]
        public IActionResult CreateSeed(Language language = Language.English,
            WordCount mnemonicWordCount = WordCount.TwentyFour,
            WordCount passphraseWordCount = WordCount.Twelve)
        {
            var seed = _walletService.CreateSeed(language, mnemonicWordCount);
            var passphrase = _walletService.CreateSeed(language, passphraseWordCount);

            return new ObjectResult(new
            {
                seed,
                passphrase
            });
        }

        // TODO: does this method expose too much (full path)? is this even required?
        [HttpGet("list", Name = "List")]
        public IActionResult List()
        {
            var walletListResult = _walletService.WalletList();

            if (walletListResult.Item1 is null)
            {
                return new BadRequestObjectResult(walletListResult.Item2 as string);
            }

            return new OkObjectResult(walletListResult.Item1 as List<string>);
        }

        [HttpPost("history", Name = "History")]
        public IActionResult History([FromBody] Credentials credentials)
        {
            return GetHistory(credentials);
        }

        /// <summary>
        ///
        /// </summary>
        /// <param name="data"></param>
        /// <returns></returns>
        [HttpPost("transaction", Name = "CreateTransaction")]
        public IActionResult CreateTransaction([FromBody] byte[] data)
        {
            var payment = MessagePackSerializer.Deserialize<SendPayment>(data);
            using var identifier = payment.Credentials.Identifier.ToSecureString();
            using var pass = payment.Credentials.Passphrase.ToSecureString();

            if(Session.AreCredentialsValid(identifier, pass))
            {
                var session = new Session(identifier, pass);
                var senderAddress = session.KeySet.StealthAddress;

                session.SessionType = payment.SessionType;
                var transaction = new WalletTransaction
                {
                    Delay = 5,
                    Payment = payment.Amount,
                    Reward = payment.SessionType == SessionType.Coinstake ? payment.Reward : 0,
                    Memo = payment.Memo,
                    RecipientAddress = payment.Address,
                    WalletType = WalletType.Send,
                    SenderAddress = senderAddress,
                    IsVerified = false
                };

                var walletTransaction = _walletService.CreateTransaction(session, ref transaction);
                if (walletTransaction.Item1 is null)
                {
                    return new StatusCodeResult(StatusCodes.Status404NotFound);
                }
                else
                {
                    return new ObjectResult(new { messagepack = transaction.Transaction.Serialize() });
                }
            }
            return new BadRequestObjectResult("Invalid identifier or password!");
        }

        [HttpPost("receive", Name = "Receive")]
        public IActionResult Receive([FromBody] Receive receive)
        {
            Guard.Argument(receive.Identifier, nameof(receive.Identifier)).NotNull().NotEmpty().NotWhiteSpace();
            Guard.Argument(receive.Passphrase, nameof(receive.Passphrase)).NotNull().NotEmpty().NotWhiteSpace();
            Guard.Argument(receive.PaymentId, nameof(receive.PaymentId)).NotNull().NotEmpty().NotWhiteSpace();

            using var identifier = receive.Identifier.ToSecureString();
            using var pass = receive.Passphrase.ToSecureString();

            if(Session.AreCredentialsValid(identifier, pass))
            {
                var session = new Session(identifier, pass);

                var receivePaymentResult = _walletService.ReceivePayment(session, receive.PaymentId);
                var balanceSheetResult = _walletService.History(session);
                if (receivePaymentResult.Item1 is null)
                {
                    return new BadRequestObjectResult(receivePaymentResult.Item2);
                }
                if(balanceSheetResult.Item1 is null)
                {
                    return new BadRequestObjectResult(balanceSheetResult.Item2);
                }
                var lastSheet = (balanceSheetResult.Item1 as List<BalanceSheet>).Last();
                return new OkObjectResult(new
                {
                    memo = lastSheet.Memo,
                    received = lastSheet.MoneyIn,
                    balance = $"{lastSheet.Balance}"
                });
            }
            return new BadRequestObjectResult("Invalid identifier or password!");
        }

        [HttpPost("spend", Name = "Spend")]
        public IActionResult Spend([FromBody] Spend spend)
        {
            Guard.Argument(spend.Identifier, nameof(spend.Identifier)).NotNull().NotEmpty().NotWhiteSpace();
            Guard.Argument(spend.Passphrase, nameof(spend.Passphrase)).NotNull().NotEmpty().NotWhiteSpace();
            Guard.Argument(spend.Address, nameof(spend.Address)).NotNull().NotEmpty().NotWhiteSpace();
            Guard.Argument(spend.Amount, nameof(spend.Amount)).Positive();

            using var identifier = spend.Identifier.ToSecureString();
            using var pass = spend.Passphrase.ToSecureString();

            if(Session.AreCredentialsValid(identifier, pass))
            {
                var session = new Session(identifier, pass);
                var senderAddress = session.KeySet.StealthAddress;

                session.SessionType = SessionType.Coin;
                var transaction = new WalletTransaction
                {
                    Memo = spend.Memo,
                    Payment = spend.Amount.ConvertToUInt64(),
                    RecipientAddress = spend.Address,
                    WalletType = WalletType.Send,
                    SenderAddress = senderAddress,
                    IsVerified = false
                };

                var createPaymentResult = _walletService.CreateTransaction(session, ref transaction);
                if (createPaymentResult.Item1 is null)
                {
                    return new BadRequestObjectResult(createPaymentResult.Item2);
                }

                var send = _walletService.Send(session, ref transaction);
                if (send.Item1 is null)
                {
                    return new BadRequestObjectResult(send.Item2);
                }

                var history = _walletService.History(session);
                if (history.Item1 is null)
                {
                    return new BadRequestObjectResult(history.Item2);
                }

                return new OkObjectResult(new
                {
                    balance = $"{(history.Item1 as IOrderedEnumerable<BalanceSheet>).Last().Balance}",
                    paymentId = transaction.Transaction.TxnId.ByteToHex()
                });
            }
            return new BadRequestObjectResult("Invalid identifier or password!");
        }
    }
}