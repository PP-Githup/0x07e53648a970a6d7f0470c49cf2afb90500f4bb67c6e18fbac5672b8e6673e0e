%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin, SignatureBuiltin
from starkware.cairo.common.cairo_secp.bigint import uint256_to_bigint
from starkware.cairo.common.cairo_secp.ec import EcPoint
from starkware.cairo.common.math import (
    assert_not_equal,
    assert_not_zero,
    split_felt,
)
from starkware.cairo.common.math_cmp import is_le, is_not_zero
from starkware.cairo.common.signature import verify_ecdsa_signature
from starkware.cairo.common.uint256 import Uint256, uint256_check
from starkware.starknet.common.syscalls import (
    get_block_timestamp,
    get_tx_info,
    TxInfo,
)

from lib.secp256r1.src.secp256r1.ec import verify_point
from lib.secp256r1.src.secp256r1.signature import verify_secp256r1_signature
from src.utils.constants import (
    NATIVE_STARK_SIG_LEN,
    STARK_SIG_LEN,
    SECP256R1_UINT256_SIG_LEN,
    STARK_PLUS_SECP256R1_SIG_LEN,
    REMOVE_SIGNER_WITH_ETD_SELECTOR,
    SIGNER_TYPE_SECP256R1,
    SIGNER_TYPE_STARK,
    SIGNER_TYPE_UNUSED,
    TX_VERSION_1_EST_FEE
)

// Structs
struct SignerModel {
    signer_0: felt,
    signer_1: felt,
    signer_2: felt,
    signer_3: felt,
    type: felt,
    reserved_0: felt,
    reserved_1: felt,
}

struct IndexedSignerModel {
    index: felt,
    signer: SignerModel,
}

struct DeferredRemoveSignerRequest {
    expire_at: felt,
    signer_id: felt,
}

// Events
@event
func SignerRemoveRequest(request: DeferredRemoveSignerRequest) {
}

@event
func SignerAdded(signer_id: felt, signer: SignerModel) {
}

@event
func SignerRemoved(signer_id: felt) {
}

@event
func SignerRemoveRequestCancelled(request: DeferredRemoveSignerRequest) {
}

// Storage
@storage_var
func Account_public_key() -> (public_key: felt) {
}

@storage_var
func Account_signers(idx: felt) -> (signer: SignerModel) {
}

@storage_var
func Account_signers_max_index() -> (res: felt) {
}

@storage_var
func Account_signers_num_hw_signers() -> (res: felt) {
}

@storage_var
func Account_deferred_remove_signer() -> (res: DeferredRemoveSignerRequest) {
}

namespace Signers {

    func get_signers{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    }() -> (signers_len: felt, signers: IndexedSignerModel*) {
        alloc_locals;
        let (max_id) = Account_signers_max_index.read();
        let (signers: IndexedSignerModel*) = alloc();
        let (num_signers) = _get_signers_inner(0, max_id, signers);
        return (signers_len=num_signers, signers=signers);
    }

    func _get_signers_inner{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    }(
        current_id: felt, max_id: felt, signers: IndexedSignerModel*
    ) -> (num_signers: felt) {
        let current_id_overflow = is_le(current_id, max_id);
        if (current_id_overflow == FALSE) {
            return (num_signers=0);
        }

        let (curr_signer) = Account_signers.read(current_id);
        if (curr_signer.type != SIGNER_TYPE_UNUSED) {
            assert [signers] = IndexedSignerModel(
                index=current_id,
                signer=SignerModel(
                    signer_0=curr_signer.signer_0,
                    signer_1=curr_signer.signer_1,
                    signer_2=curr_signer.signer_2,
                    signer_3=curr_signer.signer_3,
                    type=curr_signer.type,
                    reserved_0=curr_signer.reserved_0,
                    reserved_1=curr_signer.reserved_1
                    )
                );
            let (num_signers) = _get_signers_inner(
                current_id + 1, max_id, signers + IndexedSignerModel.SIZE
            );
            return (num_signers=num_signers + 1);
        } else {
            let (num_signers) = _get_signers_inner(current_id + 1, max_id, signers);
            return (num_signers=num_signers);
        }
    }

    func get_signer{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    }(index: felt) -> (signer: SignerModel) {
        let (signer) = Account_signers.read(index);

        return (signer=signer);
    }

    func add_signer{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    }(signer: SignerModel) -> (signer_id: felt) {
        // For now we only support adding 1 additional secp256r1 signer and that's it
        with_attr error_message("Signers: can only add 1 secp256r1 signer") {
            assert signer.type = SIGNER_TYPE_SECP256R1;
            let (num_hw_signers) = Account_signers_num_hw_signers.read();
            assert num_hw_signers = 0;
            Account_signers_num_hw_signers.write(num_hw_signers + 1);
        }

        // Make sure we're adding a valid secp256r1 point
        with_attr error_message("Signers: invalid secp256r1 signer") {
            let x_uint256 = Uint256(low=signer.signer_0, high=signer.signer_1);
            uint256_check(x_uint256);
            let y_uint256 = Uint256(low=signer.signer_2, high=signer.signer_3);
            uint256_check(y_uint256);
            let (x_bigint3) = uint256_to_bigint(x_uint256);
            let (y_bigint3) = uint256_to_bigint(y_uint256);
            verify_point(EcPoint(x=x_bigint3, y=y_bigint3));
        }


        let (max_id) = Account_signers_max_index.read();
        let avail_id = max_id + 1;
        Account_signers.write(avail_id, signer);
        Account_signers_max_index.write(avail_id);

        SignerAdded.emit(avail_id, signer);
        return (signer_id=avail_id);
    }

    func swap_signers{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    }(
        remove_index: felt,
        added_signer: SignerModel,
        in_multisig_mode: felt
) -> (signer_id: felt) {
        alloc_locals;

        let (local tx_info: TxInfo*) = get_tx_info();
        let (multi_signers_len, multi_signers) = resolve_signers_from_sig(
            tx_info.signature_len, tx_info.signature);

        // We only allow hw signer to swap unless we're in multisig then seed can also
        // initiate or approve swap_signers
        // If we arrived here in multisig then it's either
        // 1. A valid second signer from sign_pending_multisig flow
        // 2. A valid multi-signer 2nd sig
        // In both cases we should allow the swap to proceed
        with_attr error_message(
            "Signers: can only swap secp256r1 signers using a secp256r1 signer") {
            // DeMorgan on valid_signer OR multisig mode
            assert (1 - in_multisig_mode) * is_not_zero(
                multi_signers[0].signer.type - SIGNER_TYPE_SECP256R1) = FALSE;
        }

        with_attr error_message("Signers: cannot remove signer 0") {
            assert_not_equal(remove_index, 0);
        }
        let (removed_signer) = Account_signers.read(remove_index);
        with_attr error_message(
            "Signers: swap only supported for secp256r1 signer") {
            assert added_signer.type = SIGNER_TYPE_SECP256R1;
            assert removed_signer.type = SIGNER_TYPE_SECP256R1;
        }

        // At this point we verified
        // 1. a secp256r1 signer issued the request
        // 2. we're removing a secp256r1 signer
        // 3. we're adding a secp256r1 signer instead of the same type

        remove_signer(remove_index);

        let (added_signer_id) = add_signer(added_signer);

        return (signer_id=added_signer_id);
    }

    func remove_signer{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    }(index: felt) -> () {
        // Make sure we remove a hw signer, this also implies that there is one
        let (removed_signer) = Account_signers.read(index);
        with_attr error_message("Signers: tried removing invalid signer") {
            assert removed_signer.type = SIGNER_TYPE_SECP256R1;
        }

        Account_signers.write(
            index,
            SignerModel(
            signer_0=SIGNER_TYPE_UNUSED,
            signer_1=SIGNER_TYPE_UNUSED,
            signer_2=SIGNER_TYPE_UNUSED,
            signer_3=SIGNER_TYPE_UNUSED,
            type=SIGNER_TYPE_UNUSED,
            reserved_0=SIGNER_TYPE_UNUSED,
            reserved_1=SIGNER_TYPE_UNUSED
            ),
        );

        Account_deferred_remove_signer.write(
            DeferredRemoveSignerRequest(
            expire_at=0,
            signer_id=0
            )
        );

        let (num_hw_signers) = Account_signers_num_hw_signers.read();
        // enforce only 1 additional signer - when support more need to guarantee
        // that non-hws cannot remove hws
        assert num_hw_signers = 1;
        Account_signers_num_hw_signers.write(num_hw_signers - 1);

        SignerRemoved.emit(index);
        return ();
    }

    func remove_signer_with_etd{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    }(index: felt, account_etd: felt) -> () {
        // Make sure we remove a hw signer, this also implies that there is one
        let (removed_signer) = Account_signers.read(index);
        with_attr error_message("Signers: tried removing invalid signer") {
            assert removed_signer.type = SIGNER_TYPE_SECP256R1;
        }

        let (block_timestamp) = get_block_timestamp();
        with_attr error_message("Signers: etd not initialized") {
            assert_not_zero(account_etd);
        }
        let expire_at = block_timestamp + account_etd;
        let remove_req = DeferredRemoveSignerRequest(expire_at=expire_at, signer_id=index);
        Account_deferred_remove_signer.write(remove_req);
        SignerRemoveRequest.emit(remove_req);
        return ();
    }

    func get_deferred_remove_signer_req{
        syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
    }() -> (deferred_request: DeferredRemoveSignerRequest) {
        let (deferred_request) = Account_deferred_remove_signer.read();

        return (deferred_request=deferred_request);
    }

    func cancel_deferred_remove_signer_req{
        syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
    }(removed_signer_id: felt) -> () {
        // remove_signer_id is for future compatibility where we can possibly have multiple hw signers
        let (deferred_request) = Account_deferred_remove_signer.read();

        with_attr error_message("Signers: invalid remove signer request to cancel") {
            assert_not_zero(deferred_request.expire_at);
            assert deferred_request.signer_id = removed_signer_id;
        }

        Account_deferred_remove_signer.write(
            DeferredRemoveSignerRequest(
            expire_at=0,
            signer_id=0
            )
        );
        SignerRemoveRequestCancelled.emit(deferred_request);

        return ();
    }

    func resolve_signers_from_sig{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    }(
        signature_len: felt,
        signature: felt*
    ) -> (signers_len: felt, signers: IndexedSignerModel*) {
        alloc_locals;
        let res: IndexedSignerModel* = alloc();
        // "native" stark signature
        if (signature_len == NATIVE_STARK_SIG_LEN) {
            let (seed_signer) = Account_signers.read(0);
            let indexed_signer = IndexedSignerModel(
                index=0,
                signer=seed_signer,
            );
            assert res[0] = indexed_signer;
            return (signers_len=1, signers=res);
        }

        let (local signer_1: SignerModel) = Account_signers.read(signature[0]);
        if (signature_len == STARK_SIG_LEN) {
            with_attr error_message("Signers: expected stark signer") {
                assert signer_1.type = SIGNER_TYPE_STARK;
            }
            assert res[0] = IndexedSignerModel(
                index=signature[0],
                signer=signer_1,
            );
            return (signers_len=1, signers=res);
        }

        if (signature_len == SECP256R1_UINT256_SIG_LEN) {
            with_attr error_message("Signers: expected secp256r1 signer") {
                assert signer_1.type = SIGNER_TYPE_SECP256R1;
            }
            assert res[0] = IndexedSignerModel(
                index=signature[0],
                signer=signer_1,
            );
            return (signers_len=1, signers=res);

        }

        if (signature_len == STARK_PLUS_SECP256R1_SIG_LEN) {
            if (signer_1.type == SIGNER_TYPE_STARK) {
                // Currently only supports seed + secp256r1 combination
                // (id_stark, r, s, id_secp256r1, r0, r1, s0, s1)
                assert res[0] = IndexedSignerModel(
                    index=signature[0],
                    signer=signer_1,
                );

                // stark sig is 3 felts (id, r, s) so offset to next sig is 3
                let signer_2_id = signature[3];
                let (signer_2) = Account_signers.read(signer_2_id);
                with_attr error_message("Signers: expected secp256r1 signer") {
                    assert signer_2.type = SIGNER_TYPE_SECP256R1;
                }
                assert res[1] = IndexedSignerModel(
                    index=signer_2_id,
                    signer=signer_2,
                );
                return (signers_len=2, signers=res);
            }
        }


        with_attr error_message("Signers: unexpected signature") {
            assert 1=0;
        }
        return (signers_len=0, signers=cast(0, IndexedSignerModel*));
    }

    func apply_elapsed_etd_requests{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    }(block_timestamp: felt) -> () {
        let (remove_signer_req) = Account_deferred_remove_signer.read();
        let have_remove_signer_etd = is_not_zero(remove_signer_req.expire_at);
        let remove_signer_etd_expired = is_le(remove_signer_req.expire_at, block_timestamp);

        if (have_remove_signer_etd * remove_signer_etd_expired == TRUE) {
            remove_signer(remove_signer_req.signer_id);
            return();
        }

        return ();
    }

    func signers_validate{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        ecdsa_ptr: SignatureBuiltin*,
    }(
        call_array_len: felt, call_0_to: felt, call_0_sel: felt,
        calldata_len: felt, calldata: felt*,
        tx_info: TxInfo*, block_timestamp: felt, block_num: felt, is_estfee: felt,
        multi_signers_len: felt, multi_signers: IndexedSignerModel*,
        in_multisig_mode: felt, num_secp256r1_signers: felt,
    ) -> (valid: felt) {
        // Authorize Signer
        _authorize_signer(
            tx_info.account_contract_address,
            tx_info.signature_len, tx_info.signature,
            call_array_len, call_0_to, call_0_sel,
            block_timestamp,
            in_multisig_mode,
            multi_signers_len, multi_signers,
            num_secp256r1_signers,
        );

        // For estimate fee txns we skip sig validation - client side should account for it
        if (is_estfee == TRUE) {
            return (valid = TRUE);
        }

        // Validate signature
        with_attr error_message("Signers: invalid signature") {
            let (is_valid) = is_valid_signature(
                tx_info.transaction_hash, tx_info.signature_len, tx_info.signature,
                multi_signers_len, multi_signers,
            );
            assert is_valid = TRUE;
        }

        return (valid=TRUE);
    }

    func _authorize_signer{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    } (
        self: felt,
        signature_len: felt, signature: felt*,
        call_array_len: felt, call_0_to: felt, call_0_sel: felt,
        block_timestamp: felt,
        in_multisig_mode: felt,
        multi_signers_len: felt, multi_signers: IndexedSignerModel*,
        num_secp256r1_signers: felt,
    ) -> () {
        alloc_locals;

        // Dont limit txns on: not(secp256r1) OR multisig
        // the if below is boolean equivalent via DeMorgan identity
        if (num_secp256r1_signers * (1 - in_multisig_mode) == FALSE) {
            return ();
        }

        with_attr error_message(
            "Signers: single-signer sig expected not in multisig mode") {
                assert multi_signers_len = 1;
        }

        if (multi_signers[0].signer.type == SIGNER_TYPE_SECP256R1) {
            // We either don't have a pending removal, or it wasn't expired yet
            // so we're good to go
            return ();
        }

        // else: At this point we have hws and not in multisig
        // Limit seed signer only to ETD signer removal
        with_attr error_message("Signers: invalid entry point for seed signing") {
            assert multi_signers[0].signer.type = SIGNER_TYPE_STARK;
            assert call_array_len = 1;
            assert call_0_to = self;
            assert call_0_sel = REMOVE_SIGNER_WITH_ETD_SELECTOR;
        }
        // 2. Fail if there's already a pending remove signer req
        with_attr error_message("Signers: already have a pending remove signer request") {
            let (remove_signer_req) = Account_deferred_remove_signer.read();
            assert remove_signer_req.expire_at = 0;
        }
        return ();
    }

    func _is_valid_stark_signature{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        ecdsa_ptr: SignatureBuiltin*,
    }(
        public_key: felt,
        hash: felt,
        signature_len: felt, signature: felt*
    ) -> (is_valid: felt) {
        // This interface expects a signature pointer and length to make
        // no assumption about signature validation schemes.
        // But this implementation does, and it expects a (sig_r, sig_s) pair.
        let sig_r = signature[0];
        let sig_s = signature[1];

        verify_ecdsa_signature(
            message=hash, public_key=public_key, signature_r=sig_r, signature_s=sig_s
        );

        return (is_valid=TRUE);
    }

    func _is_valid_secp256r1_signature{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    }(
        signer: SignerModel,
        hash: felt,
        signature_len: felt, signature: felt*
    ) -> (is_valid: felt) {
        // x,y were verified in add_signer
        let (x) = uint256_to_bigint(Uint256(low=signer.signer_0, high=signer.signer_1));
        let (y) = uint256_to_bigint(Uint256(low=signer.signer_2, high=signer.signer_3));
        // validate r,s
        let r_uint256 = Uint256(low=signature[0], high=signature[1]);
        uint256_check(r_uint256);
        let s_uint256 = Uint256(low=signature[2], high=signature[3]);
        uint256_check(s_uint256);
        let (r_bigint3) = uint256_to_bigint(r_uint256);
        let (s_bigint3) = uint256_to_bigint(s_uint256);
        let (hash_high, hash_low) = split_felt(hash);
        let (hash_bigint3) = uint256_to_bigint(Uint256(low=hash_low, high=hash_high));
        verify_secp256r1_signature(hash_bigint3, r_bigint3, s_bigint3, EcPoint(x=x, y=y));
        return (is_valid=TRUE);
    }

    func is_valid_signature_for_mode{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        ecdsa_ptr: SignatureBuiltin*,
    } (
        hash: felt,
        signature_len: felt, signature: felt*,
        multisig_num_signers: felt,
        have_secp256r1_signer: felt,
    ) -> (is_valid: felt) {
        let (multi_signers_len , multi_signers) = resolve_signers_from_sig(
                signature_len, signature);
        tempvar is_stark_sig = 1 - is_not_zero((signature_len - NATIVE_STARK_SIG_LEN)*(signature_len - STARK_SIG_LEN));
        tempvar is_secp256r1_sig = 1 - is_not_zero(signature_len - SECP256R1_UINT256_SIG_LEN);
        tempvar is_multisig_sig = is_le(2, multi_signers_len);
        tempvar in_multisig_mode = is_not_zero(multisig_num_signers);

        // only 1 of the _sig params will be assigned 1 and will choose the correct
        // condition below
        if ((is_stark_sig * (1 - have_secp256r1_signer) +
            is_secp256r1_sig * (1 - in_multisig_mode) +
            is_multisig_sig * in_multisig_mode) == TRUE) {
            return is_valid_signature(
                hash,
                signature_len, signature,
                multi_signers_len, multi_signers,
            );
        }

        return (is_valid = FALSE);
    }

    func is_valid_signature{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr,
        ecdsa_ptr: SignatureBuiltin*,
    }(
        hash: felt,
        signature_len: felt, signature: felt*,
        multi_signers_len: felt, multi_signers: IndexedSignerModel*,
    ) -> (is_valid: felt) {
        alloc_locals;

        // Single sig consumer-multisig flow - stark + secp256r1
        if (multi_signers_len == 2 and multi_signers[0].signer.type == SIGNER_TYPE_STARK) {
            let (valid) = Signers._is_valid_stark_signature(
                multi_signers[0].signer.signer_0,
                hash,
                2, signature + 1
            );

            with_attr error_message("Multisig: invalid stark signer sig") {
                assert valid=TRUE;
            }

            let (valid) = Signers._is_valid_secp256r1_signature(
                multi_signers[1].signer,
                hash,
                4, signature + 4
            );

            with_attr error_message("Multisig: invalid secp256r1 signer sig") {
                assert valid=TRUE;
            }

            return (is_valid=TRUE);

        }

        if (multi_signers_len == 1 and multi_signers[0].signer.type == SIGNER_TYPE_STARK) {
            let sig_offset = is_not_zero(signature_len - NATIVE_STARK_SIG_LEN);  // Support native stark sig
            _is_valid_stark_signature(
                multi_signers[0].signer.signer_0,
                hash,
                signature_len - sig_offset, signature + sig_offset,
            );
            return (is_valid=TRUE);
        }

        if (multi_signers_len == 1 and multi_signers[0].signer.type == SIGNER_TYPE_SECP256R1) {
            _is_valid_secp256r1_signature(
                multi_signers[0].signer,
                hash,
                signature_len - 1, signature + 1
            );
            return (is_valid=TRUE);
        }

        // Unsupported signer type!
        with_attr error_message("Signers: unsupported signer type") {
            assert_not_zero(0);
        }

        return (is_valid=FALSE);
    }

}
