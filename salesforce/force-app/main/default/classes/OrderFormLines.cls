/**
 * The product lines of an order form: what was sold, line by line - Rogo seats,
 * Arvo seats (sold as Rogo Notes), free seats, paid / included / free credits,
 * hosting, data connections, services, pilot fees, true-ups.
 *
 * The extractor reads them as Line_Items (OrderFormPrompt, LINE ITEMS); parse()
 * maps each to a product and works out its annual amount. The normalised list
 * is kept on the extraction (Line_Items__c) and sync() - run by the
 * Order_Form_Extraction__c trigger - keeps one Order_Form_Line__c per line, so
 * every path that writes an extraction (reads, reruns, refreshes, the
 * large-document script, backfills) gets its lines the same way.
 */
public with sharing class OrderFormLines {

    public static final List<String> PRODUCTS = new List<String>{
        'Rogo Seats', 'Arvo Seats', 'Free Seats', 'Paid Credits', 'Included Credits', 'Free Credits',
        'Hosting', 'Data Connection', 'Professional Services', 'Pilot Fee', 'True-Up', 'Other'
    };
    // Charged every period, unless the paper says otherwise (basis One-time).
    private static final Set<String> RECURRING_PRODUCTS = new Set<String>{
        'Rogo Seats', 'Arvo Seats', 'Paid Credits', 'Hosting', 'Data Connection', 'Other'
    };
    // Come with something else and carry no price of their own.
    private static final Set<String> UNPRICED = new Set<String>{ 'Free Seats', 'Included Credits', 'Free Credits' };
    // Recurring lines outside the licence fee, credit commitment and hosting -
    // part of the stated recurring total that those three fields do not hold.
    public static final Set<String> OTHER_RECURRING = new Set<String>{ 'Arvo Seats', 'Data Connection', 'Other' };

    public class Line {
        public Integer lineNo;
        public String product;
        public String label;
        public Decimal quantity;
        public Decimal unitPrice;
        public Decimal amount;
        public String basis;
        public String period;
        public String change;
        public Decimal creditsPerSeat;
        public Decimal annualAmount;
        public Boolean recurring;
        public String quote;
        public String note;
    }

    /**
     * The model's Line_Items, normalised: product and basis mapped to their
     * picklist values, the annual amount of each recurring line worked out
     * (amount as written, else unit price x quantity; per month x 12, per quarter
     * x 4, per term x 12 / term months). Empty when the reply has none.
     */
    public static List<Line> parse(Object raw, Decimal termMonths) {
        List<Line> out = new List<Line>();
        if (!(raw instanceof List<Object>)) return out;
        Integer n = 0;
        for (Object o : (List<Object>) raw) {
            if (!(o instanceof Map<String, Object>)) continue;
            Map<String, Object> m = (Map<String, Object>) o;
            Line l = new Line();
            l.lineNo = ++n;
            l.label = text(m.get('label'), 255);
            l.product = mapProduct(str(m.get('product')), l.label);
            l.quantity = num(m.get('quantity'));
            l.unitPrice = num(m.get('unit_price'));
            l.amount = num(m.get('amount'));
            l.basis = mapBasis(str(m.get('basis')));
            l.period = mapPeriod(str(m.get('period')));
            l.change = mapChange(str(m.get('change')));
            l.creditsPerSeat = num(m.get('credits_per_seat'));
            l.quote = text(m.get('quote'), 2000);
            annualise(l, termMonths);
            out.add(l);
        }
        return out;
    }

    private static void annualise(Line l, Decimal termMonths) {
        l.recurring = RECURRING_PRODUCTS.contains(l.product) && l.basis != 'One-time';
        if (UNPRICED.contains(l.product) || !l.recurring) return;
        Decimal value = l.amount;
        String how = null;
        if (value == null && l.unitPrice != null && l.quantity != null) {
            value = l.unitPrice * l.quantity;
            how = l.unitPrice + ' x ' + l.quantity;
        }
        if (value == null || l.basis == null) return;
        Decimal annual;
        if (l.basis == 'Annual') annual = value;
        else if (l.basis == 'Monthly') annual = value * 12;
        else if (l.basis == 'Quarterly') annual = value * 4;
        else if (l.basis == 'Term' && termMonths != null && termMonths > 0) annual = (value * 12).divide(termMonths, 2);
        if (annual == null) return;
        l.annualAmount = annual.setScale(2, RoundingMode.HALF_UP);
        if (how != null || l.basis != 'Annual') {
            l.note = (how != null ? how : String.valueOf(value)) + ' ' + l.basis.toLowerCase()
                + (l.basis == 'Monthly' ? ' x 12' : l.basis == 'Quarterly' ? ' x 4'
                    : l.basis == 'Term' ? ' x 12/' + termMonths : '') + ' = ' + l.annualAmount + ' a year';
        }
    }

    /** The annual amount of the recurring lines of these products (null when there are none). */
    public static Decimal annualFor(List<Line> lines, Set<String> products) {
        Decimal total;
        for (Line l : lines) {
            if (l.recurring != true || l.annualAmount == null || !products.contains(l.product)) continue;
            total = (total == null ? 0 : total) + l.annualAmount;
        }
        return total;
    }

    /** The quantity on the lines of this product (null when there are none). */
    public static Decimal quantityOf(List<Line> lines, String product) {
        Decimal total;
        for (Line l : lines) {
            if (l.product != product || l.quantity == null) continue;
            total = (total == null ? 0 : total) + l.quantity;
        }
        return total;
    }

    /** The seats on the Rogo / Arvo seat lines priced at this unit price (null when none). */
    public static Decimal seatsAt(List<Line> lines, Decimal unitPrice) {
        Decimal total;
        for (Line l : lines) {
            if ((l.product != 'Rogo Seats' && l.product != 'Arvo Seats') || l.quantity == null
                    || l.unitPrice == null || l.unitPrice != unitPrice) continue;
            total = (total == null ? 0 : total) + l.quantity;
        }
        return total;
    }

    /** The annual amount of every recurring line (null when none is priced). */
    public static Decimal recurringAnnual(List<Line> lines) {
        return annualFor(lines, new Set<String>(PRODUCTS));
    }

    /** Whether any line restates a total (on an amendment) rather than listing a change. */
    public static Boolean restatesTotal(List<Line> lines) {
        for (Line l : lines) if (l.change == 'Total') return true;
        return false;
    }

    public static String toJson(List<Line> lines) {
        return (lines == null || lines.isEmpty()) ? null : JSON.serialize(lines);
    }

    public static List<Line> fromJson(String serialized) {
        if (String.isBlank(serialized)) return new List<Line>();
        try {
            return (List<Line>) JSON.deserialize(serialized, List<Line>.class);
        } catch (Exception e) {
            return new List<Line>();
        }
    }

    // ===== Aligning the lines with the extraction's seat fee / credit split =====

    private static final Set<String> AMEND_TYPES = new Set<String>{ 'Upsell', 'Downsell', 'Contract Restructure' };

    /**
     * Make the lines tell the same story as the extraction's fields, which split
     * the seat fee (License_Fees__c) from the credits (Credit_Commit_Fee__c when
     * the paper prices them on their own; none when they come with the seats):
     *  - a credit commitment is a Paid Credits line priced at it; credits with no
     *    commitment are an Included Credits line with no price of its own;
     *  - a seat line that holds seats + credits in one amount is split into the
     *    seat fee and the credits line;
     *  - a line the read left out (seats, credits, free credits) is added from the
     *    extraction's own figures.
     * A line's own figures are never overwritten - only filled or split. Returns
     * what was changed, for the evidence.
     */
    public static List<String> alignWith(List<Line> lines, Order_Form_Extraction__c row, Decimal termMonths) {
        List<String> notes = new List<String>();
        // A meeting assistant line read as "Other" (stored before the name was known) is Arvo.
        for (Line l : lines) {
            if (l.product == 'Other' && namesArvo(l.label)) {
                l.product = 'Arvo Seats';
                annualise(l, termMonths);
                notes.add('Line ' + l.lineNo + ' ("' + l.label + '") is Rogo\'s meeting assistant (Arvo / Rogo Notes), '
                    + 'not Other.');
            }
        }
        Boolean amend = AMEND_TYPES.contains(row.Type__c);
        String basis = mapBasis(row.Value_Basis__c);
        Decimal seatFee = row.License_Fees__c;
        Decimal commitFee = row.Credit_Commit_Fee__c;
        Decimal credits = (amend && row.Credits_Added__c != null) ? row.Credits_Added__c : row.Credits_Purchased__c;
        Decimal seats = (amend && row.Seats_Added__c != null) ? row.Seats_Added__c : row.Seat_Licenses__c;

        // Credits: paid by a commitment, or included with the seats.
        Line paid = first(lines, 'Paid Credits');
        Line included = first(lines, 'Included Credits');
        if (commitFee != null && commitFee > 0) {
            Line target = paid != null ? paid : included;
            if (target == null) {
                target = added(lines, 'Paid Credits', 'Credit Commitment', credits, row.Credits_Period__c, amend);
                notes.add('Added a Paid Credits line for the ' + commitFee + ' credit commitment.');
            } else if (target.product != 'Paid Credits') {
                target.product = 'Paid Credits';
                notes.add('Line ' + target.lineNo + ' is paid by the ' + commitFee + ' credit commitment, not included.');
            }
            if (target.amount == null && target.unitPrice == null) { target.amount = commitFee; target.basis = 'Annual'; }
            if (target.quantity == null) target.quantity = credits;
        } else if (credits != null && credits > 0) {
            Line target = included;
            if (target == null && paid != null && paid.amount == null && paid.unitPrice == null) {
                target = paid;
                target.product = 'Included Credits';
                notes.add('Line ' + target.lineNo + ' has no price of its own: the credits come with the seats.');
            }
            if (target == null && paid == null) {
                target = added(lines, 'Included Credits', 'Credit Allocation', credits, row.Credits_Period__c, amend);
                notes.add('Added an Included Credits line for the ' + credits + ' credits that come with the seats.');
            }
            if (target != null && target.quantity == null) target.quantity = credits;
        }
        if (row.Free_Credits__c != null && row.Free_Credits__c > 0 && first(lines, 'Free Credits') == null) {
            added(lines, 'Free Credits', 'Free Credits', row.Free_Credits__c, row.Credits_Period__c, false);
            notes.add('Added a Free Credits line for ' + row.Free_Credits__c + ' complimentary credits.');
        }

        // Seats: the seat fee, split out of a seats + credits amount.
        Line rogo = first(lines, 'Rogo Seats');
        Line arvo = first(lines, 'Arvo Seats');
        Boolean arvoOnly = rogo == null && arvo != null && (seats == null || arvo.quantity == seats);
        if (rogo == null && !arvoOnly && seats != null && seats > 0) {
            rogo = added(lines, 'Rogo Seats', 'Seats', seats, null, amend);
            notes.add('Added a Rogo Seats line for ' + seats + ' seats.');
        }
        if (rogo != null && seatFee != null) {
            if (rogo.amount == null && rogo.unitPrice == null) {
                rogo.amount = seatFee;
                rogo.basis = basis;
            } else if (commitFee != null && rogo.amount != null && (rogo.amount - (seatFee + commitFee)).abs() <= 1) {
                notes.add('Line ' + rogo.lineNo + ' held seats and credits together (' + rogo.amount + '); split into the '
                    + seatFee + ' seat fee and the ' + commitFee + ' credit commitment.');
                rogo.amount = seatFee;
            }
            if (rogo.quantity == null) rogo.quantity = seats;
        }
        for (Line l : lines) annualise(l, termMonths);
        return notes;
    }

    private static Line first(List<Line> lines, String product) {
        for (Line l : lines) if (l.product == product) return l;
        return null;
    }

    private static Line added(List<Line> lines, String product, String label, Decimal quantity, String period, Boolean amend) {
        Line l = new Line();
        l.lineNo = lines.size() + 1;
        l.product = product;
        l.label = label;
        l.quantity = quantity;
        l.period = mapPeriod(period);
        l.change = amend ? 'Added' : null;
        l.quote = 'Not listed as its own line by the read; from the extraction\'s fields.';
        lines.add(l);
        return l;
    }

    // ===== Keeping Order_Form_Line__c in step (Order_Form_Extraction__c trigger) =====

    public static void sync(List<Order_Form_Extraction__c> rows, Map<Id, Order_Form_Extraction__c> oldMap) {
        Map<Id, List<Line>> linesByRow = new Map<Id, List<Line>>();
        for (Order_Form_Extraction__c r : rows) {
            String before = (oldMap == null || !oldMap.containsKey(r.Id)) ? null : oldMap.get(r.Id).Line_Items__c;
            if (oldMap == null && String.isBlank(r.Line_Items__c)) continue;
            if (oldMap != null && r.Line_Items__c == before) continue;
            linesByRow.put(r.Id, fromJson(r.Line_Items__c));
        }
        if (linesByRow.isEmpty()) return;
        List<Order_Form_Line__c> stale = [SELECT Id FROM Order_Form_Line__c WHERE Extraction__c IN :linesByRow.keySet()];
        if (!stale.isEmpty()) delete stale;
        List<Order_Form_Line__c> fresh = new List<Order_Form_Line__c>();
        for (Id rowId : linesByRow.keySet()) {
            for (Line l : linesByRow.get(rowId)) fresh.add(toRecord(rowId, l));
        }
        if (!fresh.isEmpty()) insert fresh;
    }

    private static Order_Form_Line__c toRecord(Id rowId, Line l) {
        return new Order_Form_Line__c(
            Extraction__c = rowId,
            Line_Number__c = l.lineNo,
            Product__c = l.product,
            Label__c = l.label,
            Quantity__c = l.quantity,
            Unit_Price__c = l.unitPrice,
            Amount__c = l.amount,
            Basis__c = l.basis,
            Period__c = l.period,
            Change__c = l.change,
            Credits_Per_Seat__c = l.creditsPerSeat,
            Annual_Amount__c = l.annualAmount,
            Recurring__c = l.recurring == true,
            Evidence__c = l.quote,
            Notes__c = text(l.note, 255)
        );
    }

    // ===== Mapping =====

    // Rogo's AI meeting assistant is one product sold under three names: Arvo,
    // Rogo Notes and the Rogo Meeting Assistant (RKS: "Rogo Meeting Assistant Fee").
    @TestVisible private static final Pattern ARVO_NAME = Pattern.compile(
        '(?i)(arvo|rogo notes|notes seat|meeting assistant|ai meeting|note-?taker)');

    /** Whether a line's own name says it is Rogo's meeting assistant (Arvo / Rogo Notes). */
    @TestVisible
    private static Boolean namesArvo(String label) {
        return label != null && ARVO_NAME.matcher(label).find();
    }

    @TestVisible
    private static String mapProduct(String raw, String label) {
        String s = ((raw == null ? '' : raw) + ' | ' + (label == null ? '' : label)).toLowerCase();
        // The line's own name beats a catch-all "Other" (or an unknown product).
        if (namesArvo(label) && (raw == null || raw.equalsIgnoreCase('Other') || !PRODUCTS.contains(raw))) {
            return 'Arvo Seats';
        }
        for (String p : PRODUCTS) if (raw != null && raw.equalsIgnoreCase(p)) return p;
        if (ARVO_NAME.matcher(s).find()) return 'Arvo Seats';
        if (s.contains('free seat') || s.contains('complimentary seat') || s.contains('free user')) return 'Free Seats';
        if (s.contains('included credit')) return 'Included Credits';
        if (s.contains('credit') && (s.contains('free') || s.contains('complimentary') || s.contains('incentive')
                || s.contains('bonus'))) return 'Free Credits';
        if (s.contains('credit')) return 'Paid Credits';
        if (s.contains('hosting') || s.contains('single-tenant') || s.contains('dedicated')) return 'Hosting';
        if (s.contains('data connection') || s.contains('platform connection') || s.contains('data feed')) return 'Data Connection';
        if (s.contains('professional') || s.contains('implementation') || s.contains('integration')
                || s.contains('training') || s.contains('onboarding')) return 'Professional Services';
        if (s.contains('pilot') || s.contains('trial')) return 'Pilot Fee';
        if (s.contains('true-up') || s.contains('true up')) return 'True-Up';
        if (s.contains('seat') || s.contains('user') || s.contains('licen') || s.contains('platform')
                || s.contains('subscription')) return 'Rogo Seats';
        return 'Other';
    }

    @TestVisible
    private static String mapBasis(String raw) {
        if (String.isBlank(raw)) return null;
        String s = raw.toLowerCase();
        if (s.contains('one') && s.contains('time') || s.contains('once') || s.contains('upfront')) return 'One-time';
        if (s.contains('month')) return 'Monthly';
        if (s.contains('quarter')) return 'Quarterly';
        if (s.contains('term') || s.contains('period') || s.contains('contract')) return 'Term';
        if (s.contains('year') || s.contains('annual')) return 'Annual';
        return null;
    }

    private static String mapPeriod(String raw) {
        if (String.isBlank(raw)) return null;
        String s = raw.toLowerCase();
        if (s.contains('month')) return 'month';
        if (s.contains('quarter')) return 'quarter';
        if (s.contains('year') || s.contains('annual')) return 'year';
        if (s.contains('contract') || s.contains('term') || s.contains('period')) return 'contract';
        return null;
    }

    private static String mapChange(String raw) {
        if (String.isBlank(raw)) return null;
        String s = raw.toLowerCase();
        if (s.contains('add') || s.contains('change') || s.contains('increment')) return 'Added';
        if (s.contains('total') || s.contains('restat')) return 'Total';
        return null;
    }

    private static String str(Object v) { return v == null ? null : String.valueOf(v).trim(); }

    private static String text(Object v, Integer max) {
        String s = str(v);
        return String.isBlank(s) ? null : s.left(max);
    }

    private static Decimal num(Object v) {
        if (v == null) return null;
        if (v instanceof Decimal) return (Decimal) v;
        if (v instanceof Integer) return Decimal.valueOf((Integer) v);
        if (v instanceof Long) return Decimal.valueOf((Long) v);
        if (v instanceof Double) return Decimal.valueOf((Double) v);
        String s = String.valueOf(v).replaceAll('[^0-9.\\-]', '');
        if (String.isBlank(s)) return null;
        try { return Decimal.valueOf(s); } catch (Exception e) { return null; }
    }
}
