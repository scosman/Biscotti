# LLR Calibration and Thresholding

## LLR Score Interpretation

The PLDA log-likelihood ratio is:

```
LLR = log p(data | same speaker) / p(data | different speaker)
```

The output is in **nats** (natural logarithm). To convert to log10 (decibans), divide by `ln(10) = 2.3026`.

### Decision Rule with Prior Odds

Given a prior probability `P(same)` that two randomly chosen utterances are from the same speaker, the Bayes-optimal decision rule is:

```
Decide "same speaker" if:  LLR > -log(P(same) / (1 - P(same)))
                         i.e., LLR > -log_prior_odds
```

At the **equal-odds operating point** (`P(same) = 0.5`):
```
Threshold = 0   (log(1) = 0)
LLR > 0 -> same speaker
LLR < 0 -> different speaker
```

For a more conservative operating point (e.g., `P(same) = 0.01`):
```
Threshold = -log(0.01/0.99) = log(99) ≈ 4.6 nats
LLR > 4.6 -> same speaker
```

The posterior probability given the LLR is:
```
P(same | LLR) = sigmoid(LLR + log_prior_odds)
              = 1 / (1 + exp(-LLR - log_prior_odds))
```

Source: [Borgstrom 2020](https://www.ll.mit.edu/sites/default/files/publication/doc/discriminative-plda-speaker-verification-borgstrom-126429.pdf), eq. 4

---

## Why Raw PLDA Scores Need Calibration

In theory, PLDA scores are already log-likelihood ratios and should be perfectly calibrated. In practice, they are not, because:

1. **Model mismatch:** The Gaussian assumptions of PLDA do not perfectly hold
2. **Training/test domain mismatch:** The PLDA model was trained on different conditions than the test data
3. **Length normalization artifacts:** The nonlinear length normalization changes the effective distributions
4. **Finite training data:** Parameter estimates are noisy

From [Ferrer et al. 2021](https://arxiv.org/abs/2102.01760):
> "Since the assumptions made by PLDA do not exactly hold in practice, the scores produced by this model are usually badly calibrated. For this reason, the usual procedure is to post-process the PLDA scores using a calibration stage."

---

## Standard Calibration: Logistic Regression

The standard calibration procedure (Brümmer & Doddington 2013) applies an affine transformation to the raw PLDA scores:

```
calibrated_LLR = alpha * raw_score + beta
```

where `alpha` (scale) and `beta` (offset) are learned by minimizing the binary cross-entropy on a labeled development set:

```
L = -pi * sum_{same trials} log(sigmoid(alpha * s + beta))
    - (1-pi) * sum_{diff trials} log(1 - sigmoid(alpha * s + beta))
```

where `pi = P(same)` is the prior weighting.

### Key Properties

- **alpha = 1, beta = 0** means the raw scores are already well-calibrated
- **alpha close to 1** means the scores have correct "sharpness" but wrong offset
- **alpha != 1** means the scores are over- or under-confident
- The calibrated output is directly interpretable as a log-likelihood ratio

### Implementation

Available in:
- **FoCal toolkit** (Brümmer): MATLAB implementation, the original
- **BOSARIS toolkit** (Brümmer): Python/MATLAB, more complete evaluation framework
- **scikit-learn LogisticRegression** or simple gradient descent: just fit 2 parameters

Source: [Brümmer & Doddington 2013: "Likelihood-ratio calibration using prior-weighted proper scoring rules"](https://arxiv.org/abs/1307.7981), Interspeech 2013

---

## Calibration Across Conditions

A fundamental limitation of linear calibration is that it is condition-dependent:

> "This procedure usually leads to well-calibrated scores on data with similar class-conditional score distributions to those of the training data. However, this does not guarantee that calibration will be good on data from any other condition."
> -- Ferrer et al. 2021

To address this, Ferrer et al. (2021) propose a **condition-aware calibration** that uses side information (duration, channel) to adapt the calibration parameters per trial. Their DCA-PLDA system trains the entire backend discriminatively.

For Biscotti, condition variation is relatively low (same device, same room, similar duration), so simple linear calibration should suffice.

---

## Gaussian Calibration (Closed-Form)

Brümmer and van Leeuwen (2013) showed that for perfectly Gaussian PLDA score distributions, the calibration parameters have a closed form:

If same-speaker scores `~ N(mu_s, sigma^2)` and different-speaker scores `~ N(mu_d, sigma^2)` (same variance), then:

```
alpha = 1 / sigma^2
beta = -(mu_s + mu_d) / (2 * sigma^2)

And: mu_s = mu_d + sigma^2  (a consequence of the calibration identity)
```

The key result: **the log-likelihood-ratio of the log-likelihood-ratio is the log-likelihood-ratio**. This self-referential property constrains the score distributions to be Gaussian with linked parameters.

Source: [Brümmer & van Leeuwen 2013: "The distribution of calibrated likelihood-ratios in speaker recognition"](https://arxiv.org/abs/1304.1199)

---

## Practical Thresholding for Biscotti

For the Biscotti use case (voiceprint matching across meetings), the threshold depends on the acceptable error rates:

### Equal Error Rate (EER) Threshold

The EER threshold is the point where false accept rate = false reject rate. This corresponds to a specific LLR value that depends on the system's performance. It is NOT necessarily 0 (even for well-calibrated systems, because the prior odds are application-dependent).

### Application-Specific Threshold

For speaker identification (selecting the best match from a gallery), the threshold serves a different purpose: it's a **rejection threshold** below which no match is accepted. This should be set based on:

1. The score distribution of same-speaker and different-speaker trials from a development set
2. The acceptable false positive rate for the application
3. The prior probability of the test speaker being in the gallery

### Quick Calibration Without Labeled Data

If no labeled development data is available, a rough calibration can be done by:

1. Computing all pairwise scores in the gallery
2. Assuming most pairs are different speakers (true for a gallery with many speakers)
3. Fitting a Gaussian to the different-speaker score distribution
4. Setting the threshold at `mu_diff + k * sigma_diff` for some multiplier k (e.g., k=3 for low false positive rate)

This is a heuristic, not proper calibration, but is practical for an initial system.

---

## Units: Nats vs Bits vs Log10

| Unit | Base | Conversion | Usage |
|------|------|-----------|-------|
| Nats | ln | 1 nat | Natural logarithm. PLDA LLR output. |
| Bits | log2 | 1 bit = ln(2) nats ≈ 0.693 nats | Information theory convention. |
| Decibans | log10 | 1 deciban = ln(10) nats ≈ 2.303 nats | Forensics/courtroom. |

The LLR threshold at equal odds is **0** in any base.

---

## Sources

- [Brümmer & Doddington 2013: "Likelihood-ratio calibration using prior-weighted proper scoring rules"](https://arxiv.org/abs/1307.7981)
- [Brümmer & van Leeuwen 2013: "The distribution of calibrated likelihood-ratios"](https://arxiv.org/abs/1304.1199)
- [Ferrer et al. 2021: "A Speaker Verification Backend with Robust Performance"](https://arxiv.org/abs/2102.01760)
- [Borgstrom 2020: "Discriminative PLDA for Speaker Verification"](https://www.ll.mit.edu/sites/default/files/publication/doc/discriminative-plda-speaker-verification-borgstrom-126429.pdf)
