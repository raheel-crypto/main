@isTest
private class BillingAddressParserTest {

    private static void check(String raw, String street, String city, String state, String postal, String country) {
        BillingAddressParser.Parts p = BillingAddressParser.parse(raw);
        System.assertNotEquals(null, p, 'should split: ' + raw);
        System.assertEquals(street, p.street, raw);
        System.assertEquals(city, p.city, raw);
        System.assertEquals(state, p.state, raw);
        System.assertEquals(postal, p.postalCode, raw);
        System.assertEquals(country, p.country, raw);
    }

    @isTest
    static void splitsUsAddresses() {
        check('711 Fifth Avenue, New York, NY 10022', '711 Fifth Avenue', 'New York', 'NY', '10022', 'United States');
        check('53 State Street, 40th Floor, Boston, MA 02109, USA',
            '53 State Street, 40th Floor', 'Boston', 'MA', '02109', 'United States');
        check('1270 Ave of the Americas, Suite 2502, NY, NY 10020',
            '1270 Ave of the Americas, Suite 2502', 'New York', 'NY', '10020', 'United States');
        check('2882 Sand Hill Road, Suite 150, Menlo Park, California 94025',
            '2882 Sand Hill Road, Suite 150', 'Menlo Park', 'CA', '94025', 'United States');
        check('10 S Dearborn St, Floor 33, Chicago, IL, 60603-2300, United States',
            '10 S Dearborn St, Floor 33', 'Chicago', 'IL', '60603-2300', 'United States');
        check('1 Pickwick Plaza, 3rd Floor, Greenwich, CT', '1 Pickwick Plaza, 3rd Floor', 'Greenwich', 'CT', null, 'United States');
        check('100 Crescent Court, Suite 850 - Dallas, TX 75201',
            '100 Crescent Court, Suite 850', 'Dallas', 'TX', '75201', 'United States');
        check('1591 Lower Lake Court, Cardiff, CA 92007 USA', '1591 Lower Lake Court', 'Cardiff', 'CA', '92007', 'United States');
        check('1600 Wynkoop Street | Suite 200 | Denver, CO 80202',
            '1600 Wynkoop Street, Suite 200', 'Denver', 'CO', '80202', 'United States');
    }

    @isTest
    static void splitsInternationalAddresses() {
        check('86 Brook Street, London W1K 5AY', '86 Brook Street', 'London', null, 'W1K 5AY', 'United Kingdom');
        check('16 York Street, Suite 2900, Toronto, ON M5J 0E6',
            '16 York Street, Suite 2900', 'Toronto', 'ON', 'M5J 0E6', 'Canada');
        check('Level 3, 459 Church Street, Richmond, VIC. 3121',
            'Level 3, 459 Church Street', 'Richmond', 'VIC', '3121', 'Australia');
        check('Neue Mainzer Str. 52-58, 60311 Frankfurt am Main, Germany',
            'Neue Mainzer Str. 52-58', 'Frankfurt am Main', null, '60311', 'Germany');
        check('42 Rue Washington, 75008 Paris France', '42 Rue Washington', 'Paris', null, '75008', 'France');
        check('16, boulevard des Italiens, 75009 Paris, France (PO1 billing: BNP Paribas Finance Groupe, TSA 10001)',
            '16, boulevard des Italiens', 'Paris', null, '75009', 'France');
        check('GranTokyo North Tower, 9-1, Marunouchi 1-chome, Chiyoda-ku, Tokyo, 100-6752, Japan',
            'GranTokyo North Tower, 9-1, Marunouchi 1-chome, Chiyoda-ku', 'Tokyo', null, '100-6752', 'Japan');
        check('9 Raffles Place, #24-01, Republic Plaza, Singapore 048619',
            '9 Raffles Place, #24-01, Republic Plaza', 'Singapore', null, '048619', 'Singapore');
    }

    @isTest
    static void leavesAmbiguousAddressesUnsplit() {
        for (String raw : new List<String>{
                '746B Portola St San Francisco, CA 94129',      // city run into the street
                '300 Vesey Street 13th Floor New York, NY',
                '11755 Wilshire Blvd, Suite 2300',               // no city at all
                '7 Marjanishvili Str., Tbilisi, Georgia, 0102',  // "Georgia" is not a city
                '555 Madison Ave',
                '', null }) {
            System.assertEquals(null, BillingAddressParser.parse(raw), 'should not split: ' + raw);
        }
    }
}
